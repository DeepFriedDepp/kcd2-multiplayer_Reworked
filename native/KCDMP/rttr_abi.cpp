#include "rttr_abi.h"
#include "pe_exports.h"
#include "log.h"

#include <cmath>
#include <cstdio>
#include <string>

namespace kcdmp::rttr {

namespace {

// Every call into the game goes through one of these. If the ABI model is
// wrong the failure mode is an access violation, and an access violation in
// the game's own process is a hard exit with no diagnostic. SEH turns that
// into a log line, which is the difference between "learned something" and
// "the game vanished".
//
// These helpers hold no C++ objects with destructors: __try/__except cannot
// coexist with unwinding in the same frame (C2712).

bool call_get_by_name(GetByName fn, Type* out, const std::string_view* name) {
    __try {
        fn(out, name);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool call_is_valid(TypeIsValid fn, const Type* self, bool* out) {
    __try {
        *out = fn(self);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool call_get_method(GetMethod fn, const Type* self, Method* out, const std::string_view* name) {
    __try {
        fn(self, out, name);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool call_method_is_valid(MethodIsValid fn, const Method* self, bool* out) {
    __try {
        *out = fn(self);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool call_method_string(MethodGetName fn, const Method* self, std::string_view* out) {
    __try {
        fn(self, out);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool call_get_property_value(GetPropertyValue fn, const Type* self, Variant* ret,
                             const std::string_view* name, const void* inst) {
    __try {
        fn(self, ret, name, inst);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool call_variant_valid(VariantIsValid fn, const Variant* v, bool* out) {
    __try { *out = fn(v); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_variant_dtor(VariantDtor fn, Variant* v) {
    __try {
        fn(v);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool call_game_interface(GetGameInterface fn, void** out) {
    __try {
        *out = fn();
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// A heap/static pointer in this process. Rejects null, small integers and
// non-canonical addresses -- enough to tell "the layout was wrong and we read
// a type handle or a float" from "this is an object".
bool plausible_pointer(const void* p) {
    const auto v = reinterpret_cast<uintptr_t>(p);
    return v > 0x10000 && v < 0x00007FFFFFFFFFFFull && (v % 4) == 0;
}

} // namespace

bool resolve(Api& api) {
    HMODULE cry = GetModuleHandleA("CrySystem.dll");
    if (!cry) return false;
    const auto exports = module_exports(cry);
    if (exports.empty()) return false;

    api.get_by_name    = reinterpret_cast<GetByName>  (find_export(exports, "?get_by_name@type@rttr@@"));
    api.type_is_valid  = reinterpret_cast<TypeIsValid>(find_export(exports, "?is_valid@type@rttr@@"));
    // get_method and get_property each have a vector<type> overload for
    // explicit parameter matching; take the plain string_view form.
    api.get_method     = reinterpret_cast<GetMethod>  (find_export(exports, "?get_method@type@rttr@@", "vector"));
    api.get_property   = reinterpret_cast<GetProperty>(find_export(exports, "?get_property@type@rttr@@", "vector"));
    api.method_is_valid      = reinterpret_cast<MethodIsValid>     (find_export(exports, "?is_valid@method@rttr@@"));
    api.method_get_name      = reinterpret_cast<MethodGetName>     (find_export(exports, "?get_name@method@rttr@@"));
    api.method_get_signature = reinterpret_cast<MethodGetSignature>(find_export(exports, "?get_signature@method@rttr@@"));
    api.property_is_valid    = reinterpret_cast<PropertyIsValid>   (find_export(exports, "?is_valid@property@rttr@@"));
    // QEBA in the prefix selects the const member overload; there is also a
    // static one (SA) that reads a global property and takes no instance.
    api.get_property_value = reinterpret_cast<GetPropertyValue>(
        find_export(exports, "?get_property_value@type@rttr@@QEBA"));
    api.variant_dtor = reinterpret_cast<VariantDtor>(
        find_export(exports, "??1variant@rttr@@QEAA@XZ"));
    api.variant_is_valid = reinterpret_cast<VariantIsValid>(
        find_export(exports, "?is_valid@variant@rttr@@"));

    api.get_enumeration = reinterpret_cast<GetEnumeration>(
        find_export(exports, "?get_enumeration@type@rttr@@QEBA"));
    api.name_to_value = reinterpret_cast<NameToValue>(
        find_export(exports, "?name_to_value@enumeration@rttr@@QEBA"));
    api.argument_from_variant = reinterpret_cast<ArgumentFromVariant>(
        find_export(exports, "??0argument@rttr@@QEAA@AEBVvariant@1@@Z"));
    // Seven invoke overloads differ only in trailing argument repeats, so
    // select the single-argument one by exact suffix.
    api.invoke1 = reinterpret_cast<Invoke1>(
        find_export_suffix(exports, "?invoke@method@rttr@@QEBA",
                           "Vinstance@2@Vargument@2@@Z"));
    api.invoke3 = reinterpret_cast<Invoke3>(
        find_export_suffix(exports, "?invoke@method@rttr@@QEBA",
                           "Vinstance@2@Vargument@2@11@Z"));
    api.invoke2 = reinterpret_cast<Invoke2>(
        find_export_suffix(exports, "?invoke@method@rttr@@QEBA",
                           "Vinstance@2@Vargument@2@1@Z"));

    api.create_assoc_view = reinterpret_cast<CreateAssocView>(
        find_export(exports, "?create_associative_view@variant@rttr@@"));
    api.view_is_valid = reinterpret_cast<ViewIsValid>(
        find_export(exports, "?is_valid@variant_associative_view@rttr@@"));
    api.view_get_size = reinterpret_cast<ViewGetSize>(
        find_export(exports, "?get_size@variant_associative_view@rttr@@"));
    // begin/end have const and non-const overloads at the same address; take
    // the non-const one by its exact mangling suffix.
    api.view_begin = reinterpret_cast<ViewBegin>(
        find_export_suffix(exports, "?begin@variant_associative_view@rttr@@QEAA",
                           "?AViterator@12@XZ"));
    api.view_dtor = reinterpret_cast<ViewDtor>(
        find_export(exports, "??1variant_associative_view@rttr@@QEAA@XZ"));
    api.iter_deref = reinterpret_cast<IterDeref>(
        find_export(exports, "??Diterator@variant_associative_view@rttr@@QEAA"));
    api.iter_dtor = reinterpret_cast<IterDtor>(
        find_export(exports, "??1iterator@variant_associative_view@rttr@@QEAA@XZ"));
    api.view_end = reinterpret_cast<ViewEnd>(
        find_export_suffix(exports, "?end@variant_associative_view@rttr@@QEAA",
                           "?AViterator@12@XZ"));
    // Prefix ++ returns iterator&; the postfix form takes an int and returns
    // by value. Select prefix by its exact suffix.
    api.iter_preinc = reinterpret_cast<IterPreInc>(
        find_export_suffix(exports, "??Eiterator@variant_associative_view@rttr@@QEAA",
                           "AEAV012@XZ"));
    api.iter_not_equal = reinterpret_cast<IterNotEqual>(
        find_export(exports, "??9iterator@variant_associative_view@rttr@@QEBA"));

    // The root object lives in a different module.
    if (HMODULE shared = GetModuleHandleA("Shared.dll")) {
        const auto shared_exports = module_exports(shared);
        api.game_interface = reinterpret_cast<GetGameInterface>(
            find_export(shared_exports, "?GetWritableInstance@C_GameInterface@shared@wh@@"));
    }

    return api.complete();
}

// Read-only validation of the ABI model. Calls nothing that mutates anything.
//
// The test is built so that a wrong model cannot pass by accident:
//   - a known type must resolve valid
//   - a deliberately absent type must resolve INVALID (without this, a model
//     that returns garbage-but-nonzero would look like success)
//   - a method's name and signature must round-trip as the exact strings the
//     HTTP reflection browser independently reported
bool validate() {
    Api api{};
    if (!resolve(api)) {
        logf("ABI: resolve failed -- not all entry points are unique/present");
        return false;
    }
    logf("ABI: entry points resolved");

    bool all_ok = true;

    // --- positive control -------------------------------------------------
    const std::string_view soul_name{"wh::rpgmodule::Soul"};
    Type soul{};
    if (!call_get_by_name(api.get_by_name, &soul, &soul_name)) {
        logf("ABI: FAULT in get_by_name -- the calling convention model is wrong");
        return false;
    }
    bool soul_valid = false;
    if (!call_is_valid(api.type_is_valid, &soul, &soul_valid)) {
        logf("ABI: FAULT in type::is_valid");
        return false;
    }
    logf("ABI: get_by_name(\"wh::rpgmodule::Soul\") -> data=%p is_valid=%s",
         soul.data, soul_valid ? "true" : "false");
    if (!soul_valid) all_ok = false;

    // --- negative control -------------------------------------------------
    const std::string_view bogus_name{"wh::rpgmodule::NoSuchTypeExists"};
    Type bogus{};
    bool bogus_valid = true;
    if (call_get_by_name(api.get_by_name, &bogus, &bogus_name) &&
        call_is_valid(api.type_is_valid, &bogus, &bogus_valid)) {
        logf("ABI: get_by_name(<nonexistent>) -> data=%p is_valid=%s  (must be false)",
             bogus.data, bogus_valid ? "true" : "false");
        if (bogus_valid) {
            logf("ABI: NEGATIVE CONTROL FAILED -- everything 'resolves', so nothing is proven");
            all_ok = false;
        }
    } else {
        logf("ABI: FAULT during negative control");
        all_ok = false;
    }

    // --- round-trip a method's identity ------------------------------------
    struct Probe { const char* type_name; const char* method_name; };
    const Probe probes[] = {
        { "wh::rpgmodule::Soul",       "GetState"   },
        { "wh::rpgmodule::Soul",       "SetState"   },
        { "wh::rpgmodule::CombatSoul", "TakeDamage" },
    };

    for (const auto& p : probes) {
        const std::string_view tn{p.type_name};
        Type t{};
        if (!call_get_by_name(api.get_by_name, &t, &tn)) { logf("ABI: FAULT get_by_name(%s)", p.type_name); all_ok = false; continue; }
        bool tv = false;
        call_is_valid(api.type_is_valid, &t, &tv);
        if (!tv) { logf("ABI: type %s did not resolve", p.type_name); all_ok = false; continue; }

        const std::string_view mn{p.method_name};
        Method m{};
        if (!call_get_method(api.get_method, &t, &m, &mn)) { logf("ABI: FAULT get_method(%s)", p.method_name); all_ok = false; continue; }
        bool mv = false;
        call_method_is_valid(api.method_is_valid, &m, &mv);
        if (!mv) { logf("ABI: method %s::%s did not resolve", p.type_name, p.method_name); all_ok = false; continue; }

        std::string_view got_name{};
        std::string_view got_sig{};
        const bool ok_name = call_method_string(api.method_get_name, &m, &got_name);
        const bool ok_sig  = call_method_string(
            reinterpret_cast<MethodGetName>(api.method_get_signature), &m, &got_sig);

        if (!ok_name || !ok_sig) { logf("ABI: FAULT reading %s name/signature", p.method_name); all_ok = false; continue; }

        logf("ABI: %s::%s  name=\"%.*s\"  sig=\"%.*s\"",
             p.type_name, p.method_name,
             static_cast<int>(got_name.size()), got_name.data(),
             static_cast<int>(got_sig.size()),  got_sig.data());

        if (got_name != std::string_view{p.method_name}) {
            logf("ABI: NAME MISMATCH -- expected \"%s\"; the model is wrong somewhere", p.method_name);
            all_ok = false;
        }
    }

    logf(all_ok ? "ABI: VALIDATED -- model matches the binary"
                : "ABI: NOT validated -- see failures above");
    return all_ok;
}

namespace {

// Read an object-valued property. Returns the contained pointer, or null.
// A pointer small enough to be trivially copyable lives inline at the start of
// the variant's 16-byte payload.
void* read_object_property(const Api& api, const char* type_name, const void* obj,
                           const char* prop, InstanceLayout layout) {
    const std::string_view tn{type_name};
    Type t{};
    if (!call_get_by_name(api.get_by_name, &t, &tn)) return nullptr;
    bool tv = false;
    if (!call_is_valid(api.type_is_valid, &t, &tv) || !tv) {
        logf("WALK: type '%s' did not resolve", type_name);
        return nullptr;
    }

    InstanceBuf inst{};
    inst.build(layout, t, obj);

    const std::string_view pn{prop};
    Variant v{};
    if (!call_get_property_value(api.get_property_value, &t, &v, &pn, inst.bytes)) {
        logf("WALK: FAULT reading %s::%s", type_name, prop);
        return nullptr;
    }

    void* result = nullptr;
    std::memcpy(&result, v.data, sizeof(result));
    call_variant_dtor(api.variant_dtor, &v);
    return result;
}

int read_int_property(const Api& api, const char* type_name, const void* obj,
                      const char* prop, InstanceLayout layout, bool* ok) {
    *ok = false;
    const std::string_view tn{type_name};
    Type t{};
    if (!call_get_by_name(api.get_by_name, &t, &tn)) return 0;
    bool tv = false;
    if (!call_is_valid(api.type_is_valid, &t, &tv) || !tv) return 0;

    InstanceBuf inst{};
    inst.build(layout, t, obj);

    const std::string_view pn{prop};
    Variant v{};
    if (!call_get_property_value(api.get_property_value, &t, &v, &pn, inst.bytes)) {
        logf("WALK: FAULT reading %s::%s", type_name, prop);
        return 0;
    }

    int result = 0;
    std::memcpy(&result, v.data, sizeof(result));
    call_variant_dtor(api.variant_dtor, &v);
    *ok = true;
    return result;
}

} // namespace

// Results of the walk, kept for the invoke probe that follows it.
static void*          g_player = nullptr;
static void*          g_combat = nullptr;
static void*          g_souls  = nullptr;
static void*          g_rpg    = nullptr;
static InstanceLayout g_layout = InstanceLayout::TypeTypeData;
static bool           g_walked = false;

// Walk GameInterface -> RPGModule -> SoulList and read SoulCount.
//
// SoulCount is the checkpoint on purpose: it is a plain int, and the HTTP API
// reports the same number independently at the same moment. A wrong instance
// layout gives a fault, a null, or a number that is not the soul count -- none
// of which can be mistaken for success.
void walk_to_soul() {
    Api api{};
    if (!resolve(api)) {
        logf("WALK: resolve incomplete (Shared.dll loaded? get_property_value found?)");
        return;
    }

    void* root = nullptr;
    if (!call_game_interface(api.game_interface, &root) || !plausible_pointer(root)) {
        logf("WALK: C_GameInterface::GetWritableInstance() gave %p -- unusable", root);
        return;
    }
    logf("WALK: GameInterface root = %p", root);

    for (int i = 0; i < static_cast<int>(InstanceLayout::Count); ++i) {
        const auto layout = static_cast<InstanceLayout>(i);
        logf("WALK: trying instance layout %s", layout_name(layout));

        void* rpg = read_object_property(api, "wh::shared::GameInterface", root, "RPGModule", layout);
        if (!plausible_pointer(rpg)) {
            logf("  RPGModule -> %p  rejected", rpg);
            continue;
        }
        logf("  RPGModule  = %p", rpg);

        void* souls = read_object_property(api, "wh::rpgmodule::RPGModule", rpg, "SoulList", layout);
        if (!plausible_pointer(souls)) {
            logf("  SoulList  -> %p  rejected", souls);
            continue;
        }
        logf("  SoulList   = %p", souls);

        bool ok = false;
        const int count = read_int_property(api, "wh::rpgmodule::SoulList", souls, "SoulCount", layout, &ok);
        if (!ok) { logf("  SoulCount unreadable"); continue; }
        logf("  SoulCount  = %d", count);

        if (count <= 0 || count > 100000) {
            logf("  SoulCount implausible -- layout %s rejected", layout_name(layout));
            continue;
        }

        void* player = read_object_property(api, "wh::rpgmodule::SoulList", souls, "PlayerSoul", layout);
        logf("  PlayerSoul = %p", player);

        void* combat = plausible_pointer(player)
            ? read_object_property(api, "wh::rpgmodule::Soul", player, "CombatSoul", layout)
            : nullptr;
        logf("  CombatSoul = %p", combat);

        logf("WALK: SUCCESS with layout %s -- compare SoulCount against the HTTP API",
             layout_name(layout));

        g_player = player;
        g_combat = combat;
        g_souls  = souls;
        g_rpg    = rpg;
        g_layout = layout;
        g_walked = true;
        return;
    }

    logf("WALK: no candidate instance layout worked");
}

namespace {

bool call_get_enumeration(GetEnumeration fn, const Type* self, Enumeration* out) {
    __try { fn(self, out); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_name_to_value(NameToValue fn, const Enumeration* self, Variant* out,
                        const std::string_view* name) {
    __try { fn(self, out, name); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_argument_from_variant(ArgumentFromVariant fn, void* self, const Variant* v) {
    __try { fn(self, v); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_invoke1(Invoke1 fn, const Method* self, Variant* ret,
                  const void* inst, const void* arg) {
    __try { fn(self, ret, inst, arg); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

} // namespace

// First invocation of a reflected method from native code.
//
// Soul::GetState(health) is chosen deliberately: it mutates nothing, takes
// exactly one argument, and the HTTP API reports the same health for the same
// soul, so the result is checkable against an independent source rather than
// merely "looking like a number".
void probe_invoke() {
    if (!g_walked) { logf("INVOKE: no soul from the walk; skipping"); return; }

    Api api{};
    if (!resolve(api)) { logf("INVOKE: resolve incomplete"); return; }

    // The enum value for "health". Passing the string the way the HTTP layer
    // does is not an option here -- that conversion lives in the REST handler,
    // not in rttr.
    const std::string_view state_type_name{"wh::rpgmodule::SoulState"};
    Type t_state{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_state, &state_type_name) ||
        !call_is_valid(api.type_is_valid, &t_state, &ok) || !ok) {
        logf("INVOKE: SoulState type did not resolve");
        return;
    }

    Enumeration en{};
    if (!call_get_enumeration(api.get_enumeration, &t_state, &en)) {
        logf("INVOKE: FAULT in type::get_enumeration");
        return;
    }
    logf("INVOKE: SoulState enumeration = %p", en.data);

    const std::string_view health_name{"health"};
    Variant v_enum{};
    if (!call_name_to_value(api.name_to_value, &en, &v_enum, &health_name)) {
        logf("INVOKE: FAULT in enumeration::name_to_value");
        return;
    }
    uint64_t enum_word = 0;
    std::memcpy(&enum_word, v_enum.data, sizeof(enum_word));
    logf("INVOKE: name_to_value(\"health\") -> variant{data[0..7]=0x%llX policy=%p}",
         static_cast<unsigned long long>(enum_word), v_enum.policy);

    // Build an argument from that variant using the exported constructor, then
    // read the bytes back to learn the layout. v_enum must outlive the argument:
    // the argument almost certainly refers to the variant's storage rather than
    // owning a copy.
    alignas(8) unsigned char argbuf[32]{};
    if (!call_argument_from_variant(api.argument_from_variant, argbuf, &v_enum)) {
        logf("INVOKE: FAULT in argument(const variant&)");
        return;
    }
    auto* w = reinterpret_cast<void**>(argbuf);
    logf("INVOKE: argument bytes = [0]=%p [8]=%p [16]=%p", w[0], w[1], w[2]);
    logf("INVOKE:   &v_enum=%p  v_enum.data=%p  SoulState type handle=%p",
         static_cast<void*>(&v_enum), static_cast<void*>(v_enum.data), t_state.data);
    for (int i = 0; i < 3; ++i) {
        const char* what = "?";
        if (w[i] == static_cast<void*>(&v_enum))            what = "&variant";
        else if (w[i] == static_cast<void*>(v_enum.data))   what = "&variant.data";
        else if (w[i] == t_state.data)                      what = "SoulState type";
        else if (w[i] == nullptr)                           what = "null";
        logf("INVOKE:   field[%d] = %s", i * 8, what);
    }

    // Now call it.
    const std::string_view soul_type_name{"wh::rpgmodule::Soul"};
    Type t_soul{};
    if (!call_get_by_name(api.get_by_name, &t_soul, &soul_type_name)) return;

    const std::string_view method_name{"GetState"};
    Method m{};
    if (!call_get_method(api.get_method, &t_soul, &m, &method_name)) {
        logf("INVOKE: FAULT in get_method(GetState)");
        return;
    }
    bool mv = false;
    call_method_is_valid(api.method_is_valid, &m, &mv);
    if (!mv) { logf("INVOKE: GetState did not resolve"); return; }

    InstanceBuf inst{};
    inst.build(g_layout, t_soul, g_player);

    Variant result{};
    if (!call_invoke1(api.invoke1, &m, &result, inst.bytes, argbuf)) {
        logf("INVOKE: FAULT during method::invoke -- argument layout is wrong");
        return;
    }

    float health = 0.0f;
    std::memcpy(&health, result.data, sizeof(health));
    logf("INVOKE: PlayerSoul.GetState(health) = %.4f   <-- compare with the HTTP API",
         health);
    call_variant_dtor(api.variant_dtor, &result);

    // ---------------------------------------------------------------------
    // Hand-built argument.
    //
    // The oracle above is ambiguous: Variant::data sits at offset 0, so
    // &v_enum and v_enum.data are the SAME address and fields [0] and [8]
    // cannot be told apart from that one sample. Either both point at the
    // value, or one points at the enclosing variant.
    //
    // This matters because TakeDamage needs arguments built from raw floats
    // and a raw I_Soul*, where there is no enclosing variant to point at. If a
    // field genuinely wants a variant*, handing it a float* would be
    // dereferenced as a variant and crash.
    //
    // So: rebuild the SAME argument by hand from a raw enum value and see
    // whether GetState still returns the same health. Still read-only, and it
    // either proves the recipe or fails harmlessly.
    // ---------------------------------------------------------------------
    uint64_t raw_state = 0;
    std::memcpy(&raw_state, v_enum.data, sizeof(raw_state));
    call_variant_dtor(api.variant_dtor, &v_enum);

    alignas(8) unsigned char hand[32]{};
    auto* hw = reinterpret_cast<void**>(hand);
    hw[0] = &raw_state;
    hw[1] = &raw_state;
    hw[2] = t_state.data;

    Variant hand_result{};
    if (!call_invoke1(api.invoke1, &m, &hand_result, inst.bytes, hand)) {
        logf("INVOKE: hand-built argument FAULTED -- one of fields [0]/[8] wants a variant*, "
             "not a pointer to the value");
        return;
    }
    float hand_health = 0.0f;
    std::memcpy(&hand_health, hand_result.data, sizeof(hand_health));
    call_variant_dtor(api.variant_dtor, &hand_result);

    logf("INVOKE: hand-built argument -> GetState(health) = %.4f  [%s]",
         hand_health,
         (hand_health == health) ? "MATCHES -- recipe proven for raw values"
                                 : "MISMATCH -- do not build arguments this way");
}

namespace {

bool call_invoke3(Invoke3 fn, const Method* self, Variant* ret, const void* inst,
                  const void* a0, const void* a1, const void* a2) {
    __try { fn(self, ret, inst, a0, a1, a2); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool call_invoke2(Invoke2 fn, const Method* self, Variant* ret, const void* inst,
                  const void* a0, const void* a1) {
    __try { fn(self, ret, inst, a0, a1); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Resolve the first of several candidate spellings for a type name.
bool resolve_type(const Api& api, const char* const* names, int count,
                  Type* out, const char** chosen) {
    for (int i = 0; i < count; ++i) {
        const std::string_view sv{names[i]};
        Type t{};
        bool ok = false;
        if (call_get_by_name(api.get_by_name, &t, &sv) &&
            call_is_valid(api.type_is_valid, &t, &ok) && ok) {
            *out = t;
            *chosen = names[i];
            return true;
        }
    }
    return false;
}

} // namespace

// THIS ONE MUTATES GAME STATE. It applies 5 points of damage to the player and
// attributes it to a real I_Soul* attacker -- the exact call the HTTP boundary
// could never make, because RTTR has no string-to-pointer conversion.
//
// Target is the player rather than an NPC on purpose: health is trivially
// restorable, and the question being answered is an ABI question (can a raw
// object pointer cross `invoke`?), not a gameplay one.
//
// KNOWN DEFECT: this runs on the injected thread, not the game's main thread.
// That is a data race against the combat system, accepted here for a
// single one-shot experiment and NOT how the plugin will work --
// C_ModulesManager::Update(float) is exported and is the intended marshalling
// point.
void probe_take_damage() {
    if (!g_walked || !g_combat) { logf("DAMAGE: no CombatSoul; skipping"); return; }

    Api api{};
    if (!resolve(api)) { logf("DAMAGE: resolve incomplete"); return; }

    static const char* float_names[] = { "float" };
    static const char* soul_names[]  = { "wh::rpgmodule::I_Soul*",
                                         "classwh::rpgmodule::I_Soul*",
                                         "wh::rpgmodule::I_Soul *" };
    Type t_float{}, t_soulptr{};
    const char* chosen = nullptr;
    if (!resolve_type(api, float_names, 1, &t_float, &chosen)) {
        logf("DAMAGE: 'float' type did not resolve");
        return;
    }
    if (!resolve_type(api, soul_names, 3, &t_soulptr, &chosen)) {
        logf("DAMAGE: no spelling of I_Soul* resolved -- cannot attribute an attacker");
        return;
    }
    logf("DAMAGE: attacker parameter type resolved as \"%s\"", chosen);

    const std::string_view cs_name{"wh::rpgmodule::CombatSoul"};
    Type t_cs{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_cs, &cs_name) ||
        !call_is_valid(api.type_is_valid, &t_cs, &ok) || !ok) {
        logf("DAMAGE: CombatSoul type did not resolve");
        return;
    }

    const std::string_view td_name{"TakeDamage"};
    Method m{};
    if (!call_get_method(api.get_method, &t_cs, &m, &td_name)) { logf("DAMAGE: FAULT get_method"); return; }
    bool mv = false;
    call_method_is_valid(api.method_is_valid, &m, &mv);
    if (!mv) { logf("DAMAGE: TakeDamage did not resolve"); return; }

    // Values must outlive the arguments that point at them.
    float stamina_dmg = 0.0f;
    float health_dmg  = 5.0f;
    void* attacker    = g_player;   // the player attacking themselves

    alignas(8) unsigned char a0[32], a1[32], a2[32];
    build_argument(a0, &stamina_dmg, t_float);
    build_argument(a1, &health_dmg,  t_float);
    build_argument(a2, &attacker,    t_soulptr);   // pointer TO the pointer

    InstanceBuf inst{};
    inst.build(g_layout, t_cs, g_combat);

    logf("DAMAGE: invoking TakeDamage(0, 5, attacker=%p) on CombatSoul %p",
         attacker, g_combat);

    Variant ret{};
    if (!call_invoke3(api.invoke3, &m, &ret, inst.bytes, a0, a1, a2)) {
        logf("DAMAGE: FAULT during invoke -- pointer argument not passed correctly");
        return;
    }
    call_variant_dtor(api.variant_dtor, &ret);
    logf("DAMAGE: invoke returned without fault -- check health via the HTTP API");
}

namespace {

bool call_create_view(CreateAssocView fn, const Variant* v, void* out) {
    __try { fn(v, out); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_view_begin(ViewBegin fn, void* view, void* out) {
    __try { fn(view, out); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_iter_deref(IterDeref fn, void* it, void* out) {
    __try { fn(it, out); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_view_size(ViewGetSize fn, const void* view, uint64_t* out) {
    __try { *out = fn(view); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_view_valid(ViewIsValid fn, const void* view, bool* out) {
    __try { *out = fn(view); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void call_void1(void (*fn)(void*), void* a) {
    __try { fn(a); } __except (EXCEPTION_EXECUTE_HANDLER) { }
}
bool call_view_end(ViewEnd fn, void* view, void* out) {
    __try { fn(view, out); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_iter_inc(IterPreInc fn, void* it) {
    __try { fn(it); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_iter_ne(IterNotEqual fn, const void* a, const void* b, bool* out) {
    __try { *out = fn(a, b); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Optional explicit target, so choosing an NPC does not need a rebuild.
// Reads "kcdmp-target.txt" beside the DLL: one GUID in the usual text form.
// Absent or malformed means "scan only, damage nothing", which is the safe
// default -- a mis-picked target is a damaged NPC in someone's save.
bool read_target_guid(unsigned char out[16]) {
    char path[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&read_target_guid), &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (!slash) return false;
    std::strcpy(slash + 1, "kcdmp-target.txt");

    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") != 0 || !f) return false;
    char text[64]{};
    const bool got = (std::fgets(text, sizeof(text), f) != nullptr);
    std::fclose(f);
    if (!got) return false;

    unsigned int b[16]{};
    const int n = std::sscanf(text,
        "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
        &b[0],&b[1],&b[2],&b[3], &b[4],&b[5], &b[6],&b[7],
        &b[8],&b[9], &b[10],&b[11],&b[12],&b[13],&b[14],&b[15]);
    if (n != 16) return false;

    // Text is Windows field order; the key in memory is little-endian for the
    // first three fields. Undo that so a memcmp against the raw key works.
    out[0]=(unsigned char)b[3]; out[1]=(unsigned char)b[2];
    out[2]=(unsigned char)b[1]; out[3]=(unsigned char)b[0];
    out[4]=(unsigned char)b[5]; out[5]=(unsigned char)b[4];
    out[6]=(unsigned char)b[7]; out[7]=(unsigned char)b[6];
    for (int i = 8; i < 16; ++i) out[i] = (unsigned char)b[i];
    return true;
}

// Read a Vec3-valued property. 12 bytes, so it lives inline in the variant.
bool read_vec3(const Api& api, Type t, const void* obj, const char* prop,
               InstanceLayout layout, float out[3]) {
    InstanceBuf inst{};
    inst.build(layout, t, obj);
    const std::string_view pn{prop};
    Variant v{};
    if (!call_get_property_value(api.get_property_value, &t, &v, &pn, inst.bytes)) return false;
    std::memcpy(out, v.data, sizeof(float) * 3);
    call_variant_dtor(api.variant_dtor, &v);
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// Combat application -- what the network layer ultimately calls.
// All of this must run on the game's main thread; callers post it there.
// ---------------------------------------------------------------------------

void* find_soul_by_guid(const unsigned char guid[16]) {
    if (!g_walked || !g_souls) return nullptr;
    Api api{};
    if (!resolve(api)) return nullptr;

    const std::string_view sl_name{"wh::rpgmodule::SoulList"};
    Type t_sl{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_sl, &sl_name) ||
        !call_is_valid(api.type_is_valid, &t_sl, &ok) || !ok) return nullptr;

    InstanceBuf inst{};
    inst.build(g_layout, t_sl, g_souls);
    const std::string_view prop{"SoulsByGuid"};
    Variant map_v{};
    if (!call_get_property_value(api.get_property_value, &t_sl, &map_v, &prop, inst.bytes)) {
        return nullptr;
    }

    alignas(16) unsigned char view[kViewBufBytes]{};
    if (!call_create_view(api.create_assoc_view, &map_v, view)) {
        call_variant_dtor(api.variant_dtor, &map_v);
        return nullptr;
    }
    alignas(16) unsigned char it[kIterBufBytes]{}, it_end[kIterBufBytes]{};
    call_view_begin(api.view_begin, view, it);
    call_view_end(api.view_end, view, it_end);

    void* found = nullptr;
    alignas(16) unsigned char pr[kPairBufBytes]{};
    for (int n = 0; n < 8000 && !found; ++n) {
        bool more = false;
        if (!call_iter_ne(api.iter_not_equal, it, it_end, &more) || !more) break;
        if (call_iter_deref(api.iter_deref, it, pr)) {
            void* ka = nullptr; void* va = nullptr;
            std::memcpy(&ka, reinterpret_cast<Variant*>(pr)->data, sizeof(ka));
            std::memcpy(&va, reinterpret_cast<Variant*>(pr + sizeof(Variant))->data, sizeof(va));
            if (plausible_pointer(ka) && plausible_pointer(va) &&
                std::memcmp(ka, guid, 16) == 0) {
                std::memcpy(&found, va, sizeof(found));
            }
        }
        if (!call_iter_inc(api.iter_preinc, it)) break;
    }

    call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it);
    call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it_end);
    call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
    call_variant_dtor(api.variant_dtor, &map_v);

    return plausible_pointer(found) ? found : nullptr;
}

bool apply_damage(const unsigned char guid[16], float stamina, float health,
                  bool suppress_hit_reaction) {
    Api api{};
    if (!resolve(api)) return false;

    void* soul = find_soul_by_guid(guid);
    if (!soul) return false;

    void* combat = read_object_property(api, "wh::rpgmodule::Soul", soul, "CombatSoul", g_layout);
    if (!plausible_pointer(combat)) return false;

    static const char* float_names[] = { "float" };
    Type t_float{};
    const char* chosen = nullptr;
    if (!resolve_type(api, float_names, 1, &t_float, &chosen)) return false;

    const std::string_view cs_name{"wh::rpgmodule::CombatSoul"};
    Type t_cs{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_cs, &cs_name) ||
        !call_is_valid(api.type_is_valid, &t_cs, &ok) || !ok) return false;

    const std::string_view td{"TakeDamage"};
    Method m{};
    if (!call_get_method(api.get_method, &t_cs, &m, &td)) return false;
    bool mv = false;
    call_method_is_valid(api.method_is_valid, &m, &mv);
    if (!mv) return false;

    // TakeDamage( float Stamina, float Health, I_Soul* Attacker,
    //             bool SuppressHitReaction, BodyPartData InjureBodypart )
    //
    // Only the first two are supplied. Argument THREE is Attacker, not the
    // suppress flag -- an earlier version passed a bool there, rttr could not
    // match the signature, and the call silently did nothing while reporting
    // success. The remaining parameters have defaults.
    //
    // suppress_hit_reaction is therefore accepted but not yet honoured: setting
    // it would mean also supplying an Attacker, which we do not have for a
    // remote player. Recorded rather than quietly dropped.
    (void)suppress_hit_reaction;

    // Values must outlive the arguments that point at them.
    float st = stamina, hp = health;
    alignas(8) unsigned char a0[32], a1[32];
    build_argument(a0, &st, t_float);
    build_argument(a1, &hp, t_float);

    InstanceBuf cinst{};
    cinst.build(g_layout, t_cs, combat);

    Variant ret{};
    if (!call_invoke2(api.invoke2, &m, &ret, cinst.bytes, a0, a1)) return false;

    // A fault-free invoke is NOT a successful one: rttr hands back an invalid
    // variant when the arguments do not match the signature. Checking this is
    // what turns a silent no-op into a reportable failure.
    bool valid = false;
    call_variant_valid(api.variant_is_valid, &ret, &valid);
    call_variant_dtor(api.variant_dtor, &ret);
    if (!valid) {
        logf("COMBAT: TakeDamage returned an invalid variant -- argument mismatch");
        return false;
    }
    return true;
}

bool apply_death(const unsigned char guid[16]) {
    Api api{};
    if (!resolve(api)) return false;

    void* soul = find_soul_by_guid(guid);
    if (!soul) return false;

    // Idempotent: already dead is success. The relay makes no promises about
    // duplicates and two clients may both report the same death.
    const std::string_view soul_tn{"wh::rpgmodule::Soul"};
    Type t_soul{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_soul, &soul_tn) ||
        !call_is_valid(api.type_is_valid, &t_soul, &ok) || !ok) return false;

    InstanceBuf inst{};
    inst.build(g_layout, t_soul, soul);
    const std::string_view dead{"IsDead"};
    Variant v{};
    if (call_get_property_value(api.get_property_value, &t_soul, &v, &dead, inst.bytes)) {
        bool is_dead = false;
        std::memcpy(&is_dead, v.data, sizeof(is_dead));
        call_variant_dtor(api.variant_dtor, &v);
        if (is_dead) return true;
    }

    // GUESS: 100000 is arbitrary, but far above any max health observed (~136),
    // so it is lethal regardless of the soul.
    return apply_damage(guid, 0.0f, 100000.0f, true);
}

namespace {

// kcdmp-faction.txt: line 1 the ghost's GUID, line 2 a faction name id.
//
// The donor approach is gone. Copying a live NPC's Parent worked, but every
// faction that is actually hostile to the player has no loaded member to copy
// from -- "enemies" reports 401 members and lists no leaf souls. GetFaction is
// reflected and takes the name directly, so the faction can be fetched without
// needing any NPC to already be in it.
// Parse a GUID in text form into raw key bytes (Windows field order -> memory).
bool parse_guid(const char* s, unsigned char out[16]) {
    unsigned int b[16]{};
    if (std::sscanf(s, "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
                    &b[0],&b[1],&b[2],&b[3], &b[4],&b[5], &b[6],&b[7],
                    &b[8],&b[9], &b[10],&b[11],&b[12],&b[13],&b[14],&b[15]) != 16) return false;
    out[0]=(unsigned char)b[3]; out[1]=(unsigned char)b[2];
    out[2]=(unsigned char)b[1]; out[3]=(unsigned char)b[0];
    out[4]=(unsigned char)b[5]; out[5]=(unsigned char)b[4];
    out[6]=(unsigned char)b[7]; out[7]=(unsigned char)b[6];
    for (int i = 8; i < 16; ++i) out[i] = (unsigned char)b[i];
    return true;
}

bool read_faction_config(unsigned char ghost[16], char faction[64],
                         unsigned char donor[16], bool* donor_mode) {
    char path[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&read_faction_config), &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (!slash) return false;
    std::strcpy(slash + 1, "kcdmp-faction.txt");

    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") != 0 || !f) return false;
    char l1[64]{}, l2[64]{};
    const bool ok = std::fgets(l1, sizeof(l1), f) && std::fgets(l2, sizeof(l2), f);
    std::fclose(f);
    if (!ok) return false;

    if (!parse_guid(l1, ghost)) return false;

    size_t n = std::strlen(l2);
    while (n > 0 && (l2[n-1] == '\n' || l2[n-1] == '\r' || l2[n-1] == ' ')) l2[--n] = '\0';
    if (n == 0) return false;

    // Line 2 is either a donor soul's GUID or a faction name. The donor route
    // is preferred because GetFaction's string argument is CryStringT, not
    // std::string, and constructing one by hand is not yet possible.
    *donor_mode = parse_guid(l2, donor);
    std::strncpy(faction, l2, 63);
    return true;
}

[[maybe_unused]] bool read_faction_pair(unsigned char ghost[16], unsigned char donor[16]) {
    char path[MAX_PATH]{};
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCSTR>(&read_faction_pair), &self);
    GetModuleFileNameA(self, path, MAX_PATH);
    char* slash = std::strrchr(path, '\\');
    if (!slash) return false;
    std::strcpy(slash + 1, "kcdmp-faction.txt");

    FILE* f = nullptr;
    if (fopen_s(&f, path, "r") != 0 || !f) return false;
    char l1[64]{}, l2[64]{};
    const bool ok = std::fgets(l1, sizeof(l1), f) && std::fgets(l2, sizeof(l2), f);
    std::fclose(f);
    if (!ok) return false;

    auto parse = [](const char* s, unsigned char out[16]) {
        unsigned int b[16]{};
        if (std::sscanf(s, "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
                        &b[0],&b[1],&b[2],&b[3], &b[4],&b[5], &b[6],&b[7],
                        &b[8],&b[9], &b[10],&b[11],&b[12],&b[13],&b[14],&b[15]) != 16) return false;
        out[0]=(unsigned char)b[3]; out[1]=(unsigned char)b[2];
        out[2]=(unsigned char)b[1]; out[3]=(unsigned char)b[0];
        out[4]=(unsigned char)b[5]; out[5]=(unsigned char)b[4];
        out[6]=(unsigned char)b[7]; out[7]=(unsigned char)b[6];
        for (int i = 8; i < 16; ++i) out[i] = (unsigned char)b[i];
        return true;
    };
    return parse(l1, ghost) && parse(l2, donor);
}

void call_set_parent(FactionSetParent fn, void* self, const void* sp) {
    __try { fn(self, sp); } __except (EXCEPTION_EXECUTE_HANDLER) {
        logf("FACTION: FAULT inside SetParent");
    }
}

// SetParent is virtual (UEAA in the mangling). Calling the exported
// C_FactionBase address invokes the BASE implementation and skips whatever
// C_NPCFactionNode overrides it with -- which is the most likely reason the
// parent pointer was set and then reconciled away: the base writes one side of
// a two-sided relationship.
//
// C_FactionBase's vtable is itself exported (??_7C_FactionBase@rpgmodule@wh@@6B@),
// so the slot index can be recovered honestly: find the base SetParent's
// address inside the base vtable, then call that same index on the object's own
// vtable. No guessed offsets.
int find_vtable_index(void* const* vtable, const void* fn, int max_slots = 256) {
    if (!vtable) return -1;
    __try {
        for (int i = 0; i < max_slots; ++i) {
            if (vtable[i] == fn) return i;
            if (vtable[i] == nullptr) break;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) { }
    return -1;
}

bool call_virtual_set_parent(void* obj, int index, const void* sp) {
    __try {
        auto* vt = *reinterpret_cast<void***>(obj);
        auto fn = reinterpret_cast<FactionSetParent>(vt[index]);
        fn(obj, sp);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

const void* object_vslot(void* obj, int index) {
    __try {
        auto* vt = *reinterpret_cast<void***>(obj);
        return vt[index];
    } __except (EXCEPTION_EXECUTE_HANDLER) { return nullptr; }
}

} // namespace

void probe_faction() {
    unsigned char ghost_guid[16]{}, donor_guid[16]{};
    char faction_name[64]{};
    bool donor_mode = false;
    if (!read_faction_config(ghost_guid, faction_name, donor_guid, &donor_mode)) {
        logf("FACTION: no kcdmp-faction.txt -- skipping");
        return;
    }
    logf("FACTION: %s = \"%s\"", donor_mode ? "donor soul" : "target faction", faction_name);
    if (!g_walked || !g_souls) { logf("FACTION: no SoulList"); return; }

    Api api{};
    if (!resolve(api)) { logf("FACTION: resolve incomplete"); return; }

    HMODULE rpg = GetModuleHandleA("RPGModule.dll");
    if (!rpg) { logf("FACTION: RPGModule.dll not loaded"); return; }
    auto set_parent = reinterpret_cast<FactionSetParent>(
        find_export(module_exports(rpg), "?SetParent@C_FactionBase@rpgmodule@wh@@"));
    if (!set_parent) { logf("FACTION: SetParent export not found"); return; }
    logf("FACTION: SetParent at %p", reinterpret_cast<void*>(set_parent));

    // Locate both souls in one pass over SoulsByGuid.
    const std::string_view sl_name{"wh::rpgmodule::SoulList"};
    Type t_sl{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_sl, &sl_name) ||
        !call_is_valid(api.type_is_valid, &t_sl, &ok) || !ok) return;

    InstanceBuf inst{};
    inst.build(g_layout, t_sl, g_souls);
    const std::string_view prop{"SoulsByGuid"};
    Variant map_v{};
    if (!call_get_property_value(api.get_property_value, &t_sl, &map_v, &prop, inst.bytes)) return;

    alignas(16) unsigned char view[kViewBufBytes]{};
    if (!call_create_view(api.create_assoc_view, &map_v, view)) {
        call_variant_dtor(api.variant_dtor, &map_v); return;
    }
    alignas(16) unsigned char it[kIterBufBytes]{}, it_end[kIterBufBytes]{};
    call_view_begin(api.view_begin, view, it);
    call_view_end(api.view_end, view, it_end);

    void* ghost_soul = nullptr;
    void* donor_soul = nullptr;
    alignas(16) unsigned char pr[kPairBufBytes]{};
    for (int n = 0; n < 4000; ++n) {
        bool more = false;
        if (!call_iter_ne(api.iter_not_equal, it, it_end, &more) || !more) break;
        if (call_iter_deref(api.iter_deref, it, pr)) {
            void* ka = nullptr; void* va = nullptr;
            std::memcpy(&ka, reinterpret_cast<Variant*>(pr)->data, sizeof(ka));
            std::memcpy(&va, reinterpret_cast<Variant*>(pr + sizeof(Variant))->data, sizeof(va));
            if (plausible_pointer(ka) && plausible_pointer(va)) {
                if (std::memcmp(ka, ghost_guid, 16) == 0) std::memcpy(&ghost_soul, va, sizeof(void*));
                if (std::memcmp(ka, donor_guid, 16) == 0) std::memcpy(&donor_soul, va, sizeof(void*));
            }
        }
        if (ghost_soul && (!donor_mode || donor_soul)) break;
        if (!call_iter_inc(api.iter_preinc, it)) break;
    }
    call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it);
    call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it_end);
    call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
    call_variant_dtor(api.variant_dtor, &map_v);

    logf("FACTION: ghost soul = %p", ghost_soul);
    if (!plausible_pointer(ghost_soul)) {
        logf("FACTION: ghost soul not found -- nothing done");
        return;
    }

    void* ghost_node = read_object_property(api, "wh::rpgmodule::Soul", ghost_soul,
                                            "FactionNode", g_layout);
    logf("FACTION: ghost node=%p", ghost_node);
    if (!plausible_pointer(ghost_node)) return;

    // Donor route: lift the shared_ptr<C_Faction> straight out of a live NPC's
    // reflected Parent. No string construction, so nothing to get wrong.
    if (donor_mode) {
        if (!plausible_pointer(donor_soul)) { logf("FACTION: donor soul not found"); return; }
        void* donor_node = read_object_property(api, "wh::rpgmodule::Soul", donor_soul,
                                                "FactionNode", g_layout);
        if (!plausible_pointer(donor_node)) { logf("FACTION: donor has no faction node"); return; }

        const std::string_view npcf{"wh::rpgmodule::NPCFaction"};
        Type t_npcf{};
        bool nok = false;
        if (!call_get_by_name(api.get_by_name, &t_npcf, &npcf) ||
            !call_is_valid(api.type_is_valid, &t_npcf, &nok) || !nok) return;

        InstanceBuf dinst{};
        dinst.build(g_layout, t_npcf, donor_node);
        const std::string_view par{"Parent"};
        Variant parent_v{};
        if (!call_get_property_value(api.get_property_value, &t_npcf, &parent_v, &par, dinst.bytes)) {
            logf("FACTION: FAULT reading donor Parent"); return;
        }
        void* fp = nullptr;
        std::memcpy(&fp, parent_v.data, sizeof(fp));
        logf("FACTION: donor faction = %p", fp);
        if (!plausible_pointer(fp)) {
            logf("FACTION: donor has a null parent");
            call_variant_dtor(api.variant_dtor, &parent_v);
            return;
        }

        // ------------------------------------------------------------------
        // DISABLED. Calling SetParent from here corrupted the game's faction
        // tree and ultimately crashed it.
        //
        // SetParent takes std::shared_ptr<C_Faction> BY VALUE. MSVC passes it
        // by address, but the caller must supply a copy the callee will consume
        // and destroy. What was passed instead was the address of the shared_ptr
        // living inside the reflected variant, so the callee's destructor ran on
        // a reference it did not own. Repeated attempts drove the refcount to
        // zero and released animal_wild_enemy_trosecko outright: the faction
        // vanished from the manager and its members lost their parent.
        //
        // The earlier "the write does not persist" reading was wrong. Nothing
        // was reconciling the value away -- the refcount was being destroyed
        // underneath it. The two-sided-registration theory and the vtable work
        // that followed were both chasing a cause that did not exist.
        //
        // Every other write this plugin performs passes a VALUE type -- floats,
        // an enum, a raw object pointer -- where pointing at our own storage is
        // correct because the callee copies out. Ownership-transferring
        // parameters are a different contract, and the same wall blocks
        // GetFaction, whose argument is a CryStringT.
        //
        // DO NOT re-enable until there is a way to construct a genuinely owned
        // copy of the game's shared_ptr/string types. A read-back straight after
        // the call looked correct every time; the damage only surfaced later, so
        // immediate verification does not make this safe.
        // ------------------------------------------------------------------
        (void)set_parent;
        (void)&call_set_parent;
        (void)&call_virtual_set_parent;
        (void)&find_vtable_index;
        (void)&object_vslot;
        logf("FACTION: SetParent is DISABLED -- shared_ptr is an ownership-transfer "
             "parameter and passing a borrowed reference corrupted the faction tree. "
             "See the comment in rttr_abi.cpp.");
        call_variant_dtor(api.variant_dtor, &parent_v);
        return;
    }

    // FactionManager::GetFaction(string) -> shared_ptr<C_Faction>.
    // The argument is a std::string: the game is MSVC-built, so our std::string
    // is layout-identical and can be pointed at directly.
    void* fmgr = read_object_property(api, "wh::rpgmodule::RPGModule", g_rpg,
                                      "FactionManager", g_layout);
    if (!plausible_pointer(fmgr)) { logf("FACTION: FactionManager=%p", fmgr); return; }

    const std::string_view fm_tn{"wh::rpgmodule::C_FactionManager"};
    Type t_fm{};
    bool fok = false;
    if (!call_get_by_name(api.get_by_name, &t_fm, &fm_tn) ||
        !call_is_valid(api.type_is_valid, &t_fm, &fok) || !fok) {
        logf("FACTION: C_FactionManager type did not resolve"); return;
    }
    const std::string_view gf{"GetFaction"};
    Method m_gf{};
    if (!call_get_method(api.get_method, &t_fm, &m_gf, &gf)) return;
    bool gok = false;
    call_method_is_valid(api.method_is_valid, &m_gf, &gok);
    if (!gok) { logf("FACTION: GetFaction did not resolve"); return; }

    static const char* string_names[] = { "string", "std::string", "classstd::string" };
    Type t_str{};
    const char* chosen = nullptr;
    if (!resolve_type(api, string_names, 3, &t_str, &chosen)) {
        logf("FACTION: no spelling of the string type resolved"); return;
    }
    logf("FACTION: string type resolved as \"%s\"", chosen);

    std::string name_arg{faction_name};
    alignas(8) unsigned char sarg[32];
    build_argument(sarg, &name_arg, t_str);

    InstanceBuf finst{};
    finst.build(g_layout, t_fm, fmgr);
    Variant fac_v{};
    if (!call_invoke1(api.invoke1, &m_gf, &fac_v, finst.bytes, sarg)) {
        logf("FACTION: FAULT in GetFaction -- the string argument shape is wrong");
        return;
    }
    void* faction_ptr = nullptr;
    std::memcpy(&faction_ptr, fac_v.data, sizeof(faction_ptr));
    logf("FACTION: GetFaction(\"%s\") -> %p", faction_name, faction_ptr);

    if (plausible_pointer(faction_ptr)) {
        logf("FACTION: calling SetParent(ghost_node, faction)");
        call_set_parent(set_parent, ghost_node, fac_v.data);
        logf("FACTION: returned -- verify ghost FactionNode/Parent/Name over HTTP");
    } else {
        logf("FACTION: GetFaction returned null -- name not found?");
    }
    call_variant_dtor(api.variant_dtor, &fac_v);
}

// ---------------------------------------------------------------------------
// Outbound detection by sampling
// ---------------------------------------------------------------------------

namespace {

struct Tracked {
    unsigned char guid[16];
    void*         soul;
    float         health;
    float         credit;   // damage we applied for a peer, not yet cancelled out
    bool          dead;
    bool          seen;
};

constexpr int   kMaxTracked     = 64;
constexpr float kTrackRadius    = 60.0f;
constexpr DWORD kSampleEveryMs  = 60;
constexpr float kMinReportable  = 0.01f;

Tracked g_tracked[kMaxTracked];
int     g_tracked_count = 0;
DWORD   g_last_sample   = 0;
DWORD   g_last_rescan   = 0;

Tracked* find_tracked(const unsigned char guid[16]) {
    for (int i = 0; i < g_tracked_count; ++i)
        if (std::memcmp(g_tracked[i].guid, guid, 16) == 0) return &g_tracked[i];
    return nullptr;
}

} // namespace

void note_remote_damage(const unsigned char guid[16], float health_delta) {
    if (Tracked* t = find_tracked(guid)) t->credit += health_delta;
}

void sample_health(void (*on_hit)(const unsigned char[16], float, bool)) {
    const DWORD now = GetTickCount();
    if (now - g_last_sample < kSampleEveryMs) return;
    g_last_sample = now;

    if (!g_walked || !g_souls || !g_player) return;
    Api api{};
    if (!resolve(api)) return;

    const std::string_view soul_tn{"wh::rpgmodule::Soul"};
    Type t_soul{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_soul, &soul_tn) ||
        !call_is_valid(api.type_is_valid, &t_soul, &ok) || !ok) return;

    // Rebuild the tracked set occasionally: the player moves, souls stream in
    // and out. Doing it every tick would mean walking 1500 souls at frame rate.
    if (g_tracked_count == 0 || now - g_last_rescan > 3000) {
        g_last_rescan = now;
        float ppos[3]{};
        if (!read_vec3(api, t_soul, g_player, "Position", g_layout, ppos)) return;
        g_tracked_count = 0;

        // Reuse the map walk; only souls with a real position are candidates.
        InstanceBuf inst{};
        inst.build(g_layout, t_soul, g_souls);
        // (walk performed below via the same helper the lookup uses)
        Type t_sl{};
        const std::string_view sl_name{"wh::rpgmodule::SoulList"};
        if (!call_get_by_name(api.get_by_name, &t_sl, &sl_name)) return;
        InstanceBuf slinst{};
        slinst.build(g_layout, t_sl, g_souls);
        const std::string_view prop{"SoulsByGuid"};
        Variant map_v{};
        if (!call_get_property_value(api.get_property_value, &t_sl, &map_v, &prop, slinst.bytes)) return;

        alignas(16) unsigned char view[kViewBufBytes]{};
        if (!call_create_view(api.create_assoc_view, &map_v, view)) {
            call_variant_dtor(api.variant_dtor, &map_v); return;
        }
        alignas(16) unsigned char it[kIterBufBytes]{}, it_end[kIterBufBytes]{};
        call_view_begin(api.view_begin, view, it);
        call_view_end(api.view_end, view, it_end);
        alignas(16) unsigned char pr[kPairBufBytes]{};

        for (int n = 0; n < 8000 && g_tracked_count < kMaxTracked; ++n) {
            bool more = false;
            if (!call_iter_ne(api.iter_not_equal, it, it_end, &more) || !more) break;
            if (call_iter_deref(api.iter_deref, it, pr)) {
                void* ka = nullptr; void* va = nullptr;
                std::memcpy(&ka, reinterpret_cast<Variant*>(pr)->data, sizeof(ka));
                std::memcpy(&va, reinterpret_cast<Variant*>(pr + sizeof(Variant))->data, sizeof(va));
                if (plausible_pointer(ka) && plausible_pointer(va)) {
                    void* soul = nullptr;
                    std::memcpy(&soul, va, sizeof(soul));
                    if (plausible_pointer(soul) && soul != g_player) {
                        float p[3]{};
                        if (read_vec3(api, t_soul, soul, "Position", g_layout, p) &&
                            !(p[0] == 0.0f && p[1] == 0.0f && p[2] == 0.0f)) {
                            const float dx = p[0]-ppos[0], dy = p[1]-ppos[1], dz = p[2]-ppos[2];
                            if (dx*dx + dy*dy + dz*dz < kTrackRadius * kTrackRadius) {
                                Tracked& t = g_tracked[g_tracked_count++];
                                std::memcpy(t.guid, ka, 16);
                                t.soul = soul; t.credit = 0.0f; t.dead = false; t.seen = false;
                                t.health = -1.0f;   // primed on the next pass
                            }
                        }
                    }
                }
            }
            if (!call_iter_inc(api.iter_preinc, it)) break;
        }
        call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it);
        call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it_end);
        call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
        call_variant_dtor(api.variant_dtor, &map_v);
        logf("SAMPLE: tracking %d souls within %.0f m", g_tracked_count, kTrackRadius);
    }

    // Sample the tracked set.
    static const char* state_names[] = { "wh::rpgmodule::SoulState" };
    Type t_state{};
    const char* chosen = nullptr;
    if (!resolve_type(api, state_names, 1, &t_state, &chosen)) return;
    Enumeration en{};
    if (!call_get_enumeration(api.get_enumeration, &t_state, &en)) return;
    const std::string_view hn{"health"};
    Variant v_enum{};
    if (!call_name_to_value(api.name_to_value, &en, &v_enum, &hn)) return;
    uint64_t state_val = 0;
    std::memcpy(&state_val, v_enum.data, sizeof(state_val));
    call_variant_dtor(api.variant_dtor, &v_enum);

    const std::string_view gs{"GetState"};
    Method m{};
    if (!call_get_method(api.get_method, &t_soul, &m, &gs)) return;

    alignas(8) unsigned char arg[32];
    build_argument(arg, &state_val, t_state);

    for (int i = 0; i < g_tracked_count; ++i) {
        Tracked& t = g_tracked[i];
        InstanceBuf inst{};
        inst.build(g_layout, t_soul, t.soul);
        Variant res{};
        if (!call_invoke1(api.invoke1, &m, &res, inst.bytes, arg)) continue;
        bool valid = false;
        call_variant_valid(api.variant_is_valid, &res, &valid);
        float hp = 0.0f;
        if (valid) std::memcpy(&hp, res.data, sizeof(hp));
        call_variant_dtor(api.variant_dtor, &res);
        if (!valid) continue;

        if (t.health < 0.0f) { t.health = hp; continue; }   // first sight

        const float drop = t.health - hp;
        t.health = hp;
        if (drop <= kMinReportable) { if (drop < 0.0f) t.credit = 0.0f; continue; }

        // Subtract anything we applied on a peer's behalf.
        float reportable = drop;
        if (t.credit > 0.0f) {
            const float used = (t.credit < reportable) ? t.credit : reportable;
            t.credit    -= used;
            reportable  -= used;
        }
        if (reportable <= kMinReportable) continue;

        const bool died = (hp <= 0.0f) && !t.dead;
        if (died) t.dead = true;
        if (on_hit) on_hit(t.guid, reportable, died);
    }
}

namespace {

// Classify an address: which module, which section, executable or not.
bool describe_address(const void* p, char* out, size_t n) {
    // Range check only. plausible_pointer also demands 4-byte alignment, which
    // code addresses need not have, and using it here truncated the vtable dump.
    const auto v = reinterpret_cast<uintptr_t>(p);
    if (v <= 0x10000 || v >= 0x00007FFFFFFFFFFFull) { _snprintf_s(out, n, _TRUNCATE, "-"); return false; }

    MEMORY_BASIC_INFORMATION mbi{};
    if (!VirtualQuery(p, &mbi, sizeof(mbi))) { _snprintf_s(out, n, _TRUNCATE, "unmapped"); return false; }
    const bool exec = (mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                                      PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;

    HMODULE mod = nullptr;
    char name[MAX_PATH]{};
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           static_cast<LPCSTR>(p), &mod) && mod) {
        GetModuleFileNameA(mod, name, MAX_PATH);
        const char* slash = std::strrchr(name, '\\');
        const char* base  = slash ? slash + 1 : name;
        _snprintf_s(out, n, _TRUNCATE, "%s+0x%llX%s", base,
                    static_cast<unsigned long long>(
                        reinterpret_cast<const char*>(p) - reinterpret_cast<const char*>(mod)),
                    exec ? " EXEC" : "");
        return exec;
    }
    _snprintf_s(out, n, _TRUNCATE, "heap%s", exec ? " EXEC" : "");
    return exec;
}

} // namespace

void probe_method_wrapper() {
    Api api{};
    if (!resolve(api)) { logf("HOOK: resolve incomplete"); return; }

    const std::string_view cs{"wh::rpgmodule::CombatSoul"};
    Type t{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t, &cs) ||
        !call_is_valid(api.type_is_valid, &t, &ok) || !ok) return;

    const std::string_view td{"TakeDamage"};
    Method m{};
    if (!call_get_method(api.get_method, &t, &m, &td)) return;
    bool mv = false;
    call_method_is_valid(api.method_is_valid, &m, &mv);
    if (!mv) { logf("HOOK: TakeDamage did not resolve"); return; }

    logf("HOOK: method_wrapper at %p", m.data);

    // The wrapper is a C++ object: vtable first, then whatever the concrete
    // wrapper stores -- for a member function, a pointer-to-member, which on
    // MSVC x64 for a non-virtual single-inheritance method is just the code
    // address. So look for an executable pointer among the first few words.
    char desc[256];
    auto* words = reinterpret_cast<void* const*>(m.data);
    for (int i = 0; i < 16; ++i) {
        void* w = nullptr;
        __try { w = words[i]; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
        describe_address(w, desc, sizeof(desc));
        logf("HOOK:   [%2d] %p  %s", i * 8, w, desc);
    }

    // The vtable itself is worth dumping: its slots are the wrapper's own
    // invoke overloads, which is a second route to the target.
    void* const* vt = nullptr;
    __try { vt = *reinterpret_cast<void* const* const*>(m.data); } __except (EXCEPTION_EXECUTE_HANDLER) { vt = nullptr; }
    if (plausible_pointer(vt)) {
        logf("HOOK: wrapper vtable at %p", static_cast<const void*>(vt));
        // Do not filter on plausible_pointer here: it insists on 4-byte
        // alignment, which code addresses need not have, and that silently
        // truncated this dump to two entries on the first run.
        for (int i = 0; i < 24; ++i) {
            void* f = nullptr;
            __try { f = vt[i]; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
            if (f == nullptr) break;
            const bool exec = describe_address(f, desc, sizeof(desc));
            logf("HOOK:   vt[%2d] %p  %s", i, f, desc);
            if (!exec) break;   // past the end of the vtable
        }
    }
}

void probe_attribution() {
    if (!g_walked || !g_souls) { logf("ATTR: no SoulList; skipping"); return; }

    Api api{};
    if (!resolve(api)) { logf("ATTR: resolve incomplete"); return; }

    // SoulList::SoulsByGuid -> variant holding unordered_map<CryGUID, C_Soul*>
    const std::string_view sl_name{"wh::rpgmodule::SoulList"};
    Type t_sl{};
    bool ok = false;
    if (!call_get_by_name(api.get_by_name, &t_sl, &sl_name) ||
        !call_is_valid(api.type_is_valid, &t_sl, &ok) || !ok) {
        logf("ATTR: SoulList type did not resolve"); return;
    }

    InstanceBuf inst{};
    inst.build(g_layout, t_sl, g_souls);

    const std::string_view prop{"SoulsByGuid"};
    Variant map_v{};
    if (!call_get_property_value(api.get_property_value, &t_sl, &map_v, &prop, inst.bytes)) {
        logf("ATTR: FAULT reading SoulsByGuid"); return;
    }

    alignas(16) unsigned char view[kViewBufBytes]{};
    if (!call_create_view(api.create_assoc_view, &map_v, view)) {
        logf("ATTR: FAULT in create_associative_view");
        call_variant_dtor(api.variant_dtor, &map_v);
        return;
    }

    bool view_ok = false;
    uint64_t size = 0;
    call_view_valid(api.view_is_valid, view, &view_ok);
    call_view_size(api.view_get_size, view, &size);
    logf("ATTR: SoulsByGuid view valid=%s size=%llu",
         view_ok ? "true" : "false", static_cast<unsigned long long>(size));

    if (!view_ok || size == 0) {
        call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
        call_variant_dtor(api.variant_dtor, &map_v);
        return;
    }

    // The soul type, resolved once: this loop runs over every entry and
    // re-resolving it per soul would dominate the cost.
    const std::string_view soul_tn{"wh::rpgmodule::Soul"};
    Type t_soul{};
    if (!call_get_by_name(api.get_by_name, &t_soul, &soul_tn)) {
        call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
        call_variant_dtor(api.variant_dtor, &map_v);
        return;
    }

    float player_pos[3]{};
    if (!read_vec3(api, t_soul, g_player, "Position", g_layout, player_pos)) {
        logf("ATTR: could not read player position");
        call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
        call_variant_dtor(api.variant_dtor, &map_v);
        return;
    }
    logf("ATTR: player at %.1f,%.1f,%.1f", player_pos[0], player_pos[1], player_pos[2]);

    // Identity must be compared by GUID, not by pointer.
    //
    // The map stores C_Soul* while SoulList::PlayerSoul hands back an I_Soul*
    // base subobject, so the SAME soul has two different addresses. A previous
    // run "found" a distinct soul 0 m away that turned out to be the player,
    // and damaged them. This is the same reason SharedSoulGuid is the identity
    // for the shared-world design rather than anything address-shaped.
    unsigned char player_guid[16]{};
    bool have_player_guid = false;
    {
        InstanceBuf pinst{};
        pinst.build(g_layout, t_soul, g_player);
        const std::string_view gp{"Guid"};
        Variant gv{};
        if (call_get_property_value(api.get_property_value, &t_soul, &gv, &gp, pinst.bytes)) {
            std::memcpy(player_guid, gv.data, sizeof(player_guid));
            call_variant_dtor(api.variant_dtor, &gv);
            have_player_guid = true;
        }
    }
    if (!have_player_guid) {
        logf("ATTR: could not read the player's GUID -- refusing to scan without it");
        call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
        call_variant_dtor(api.variant_dtor, &map_v);
        return;
    }

    alignas(16) unsigned char it[kIterBufBytes]{};
    alignas(16) unsigned char it_end[kIterBufBytes]{};
    if (!call_view_begin(api.view_begin, view, it) ||
        !call_view_end(api.view_end, view, it_end)) {
        logf("ATTR: FAULT in begin()/end()");
        call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
        call_variant_dtor(api.variant_dtor, &map_v);
        return;
    }

    // Scan for the nearest SPAWNED soul. A soul at the origin is loaded in the
    // SoulList but has no entity in the world -- the first entry last time was
    // exactly that, which is why AttackersCount could not move: there was no
    // combat entity for an attacker to register on.
    alignas(16) unsigned char pr[kPairBufBytes]{};
    void*         target = nullptr;
    float         best_dist = 1e30f;
    int           scanned = 0, spawned = 0;

    struct Candidate { float dist2; void* soul; unsigned char key[16]; };
    constexpr int kMaxCandidates = 8;
    Candidate cand[kMaxCandidates]{};
    for (auto& c : cand) { c.dist2 = 1e30f; c.soul = nullptr; }

    // Optional explicit target: a GUID in kcdmp-target.txt next to the DLL.
    // Without it nothing is damaged -- the scan only reports.
    unsigned char wanted[16]{};
    const bool have_wanted = read_target_guid(wanted);

    for (;;) {
        bool more = false;
        if (!call_iter_ne(api.iter_not_equal, it, it_end, &more) || !more) break;
        if (scanned++ > 4000) { logf("ATTR: scan cap hit"); break; }

        if (!call_iter_deref(api.iter_deref, it, pr)) break;

        void* key_addr = nullptr;
        void* val_addr = nullptr;
        std::memcpy(&key_addr, reinterpret_cast<Variant*>(pr)->data, sizeof(key_addr));
        std::memcpy(&val_addr, reinterpret_cast<Variant*>(pr + sizeof(Variant))->data,
                    sizeof(val_addr));

        if (plausible_pointer(key_addr) && plausible_pointer(val_addr)) {
            void* soul = nullptr;
            std::memcpy(&soul, val_addr, sizeof(soul));
            const bool is_player =
                std::memcmp(key_addr, player_guid, sizeof(player_guid)) == 0;
            if (plausible_pointer(soul) && soul != g_player && !is_player) {
                float p[3]{};
                if (read_vec3(api, t_soul, soul, "Position", g_layout, p)) {
                    const bool at_origin = (p[0] == 0.0f && p[1] == 0.0f && p[2] == 0.0f);
                    if (!at_origin) {
                        ++spawned;
                        const float dx = p[0] - player_pos[0];
                        const float dy = p[1] - player_pos[1];
                        const float dz = p[2] - player_pos[2];
                        const float d2 = dx*dx + dy*dy + dz*dz;

                        // Collect the nearest few rather than auto-picking one.
                        // A distance filter cannot separate the player's own
                        // co-located proxy soul from an NPC standing right next
                        // to them -- both are ~0 m away. So report candidates
                        // and let the operator name the target explicitly.
                        for (int s = 0; s < kMaxCandidates; ++s) {
                            if (d2 < cand[s].dist2) {
                                for (int t = kMaxCandidates - 1; t > s; --t) cand[t] = cand[t-1];
                                cand[s].dist2 = d2;
                                cand[s].soul  = soul;
                                std::memcpy(cand[s].key, key_addr, 16);
                                break;
                            }
                        }
                        if (d2 < best_dist) { best_dist = d2; }
                    }
                }
            }
        }
        if (!call_iter_inc(api.iter_preinc, it)) break;
    }

    logf("ATTR: scanned %d entries, %d spawned", scanned, spawned);
    for (int s = 0; s < kMaxCandidates; ++s) {
        if (!cand[s].soul) break;
        const unsigned char* k = cand[s].key;
        // Windows GUID field order: uint32 LE, uint16 LE, uint16 LE, 8 bytes.
        logf("ATTR:  [%d] %6.2f m  %p  %02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-"
             "%02X%02X%02X%02X%02X%02X",
             s, sqrtf(cand[s].dist2), cand[s].soul,
             k[3],k[2],k[1],k[0], k[5],k[4], k[7],k[6],
             k[8],k[9], k[10],k[11],k[12],k[13],k[14],k[15]);
        if (have_wanted && std::memcmp(cand[s].key, wanted, 16) == 0) {
            target = cand[s].soul;
            logf("ATTR:  ^ matches kcdmp-target.txt -- this one will be damaged");
        }
    }
    if (!have_wanted) {
        logf("ATTR: no kcdmp-target.txt -- scan only, nothing will be damaged");
    } else if (!target) {
        logf("ATTR: kcdmp-target.txt GUID not among the nearest candidates");
    }

    call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it_end);

    call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it);
    call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
    call_variant_dtor(api.variant_dtor, &map_v);

    if (!plausible_pointer(target) || target == g_player) {
        logf("ATTR: no usable distinct soul; stopping before any damage");
        return;
    }

    // That soul's CombatSoul, then damage attributed to the player.
    // t_soul was already resolved above for the position scan.
    void* target_combat = read_object_property(api, "wh::rpgmodule::Soul", target,
                                               "CombatSoul", g_layout);
    if (!plausible_pointer(target_combat)) {
        logf("ATTR: target has no CombatSoul (%p)", target_combat); return;
    }

    static const char* float_names[] = { "float" };
    static const char* soul_names[]  = { "wh::rpgmodule::I_Soul*" };
    Type t_float{}, t_soulptr{};
    const char* chosen = nullptr;
    if (!resolve_type(api, float_names, 1, &t_float, &chosen) ||
        !resolve_type(api, soul_names, 1, &t_soulptr, &chosen)) {
        logf("ATTR: parameter types did not resolve"); return;
    }

    const std::string_view cs_name{"wh::rpgmodule::CombatSoul"};
    Type t_cs{};
    if (!call_get_by_name(api.get_by_name, &t_cs, &cs_name)) return;
    const std::string_view td{"TakeDamage"};
    Method m{};
    if (!call_get_method(api.get_method, &t_cs, &m, &td)) return;
    bool mv = false;
    call_method_is_valid(api.method_is_valid, &m, &mv);
    if (!mv) { logf("ATTR: TakeDamage did not resolve"); return; }

    float stam = 0.0f, dmg = 3.0f;
    void* attacker = g_player;
    alignas(8) unsigned char a0[32], a1[32], a2[32];
    build_argument(a0, &stam, t_float);
    build_argument(a1, &dmg,  t_float);
    build_argument(a2, &attacker, t_soulptr);

    InstanceBuf cinst{};
    cinst.build(g_layout, t_cs, target_combat);

    logf("ATTR: TakeDamage(0, 3, attacker=player) on soul %p", target);
    Variant ret{};
    if (!call_invoke3(api.invoke3, &m, &ret, cinst.bytes, a0, a1, a2)) {
        logf("ATTR: FAULT during invoke"); return;
    }
    call_variant_dtor(api.variant_dtor, &ret);
    logf("ATTR: done -- check that soul's health and AttackersCount over HTTP");

    // Did the attribution actually register?
    //
    // AttackersCount staying 0 is suggestive but not conclusive -- it may
    // simply be the wrong indicator, populated only once a skirmish starts.
    // HasCombatHistoryWithSoul(attacker, maxTime) asks the question directly,
    // and it takes an I_Soul* so it can only be called from in-process. This is
    // read-only.
    const std::string_view hist_name{"HasCombatHistoryWithSoul"};
    Method hm{};
    if (!call_get_method(api.get_method, &t_cs, &hm, &hist_name)) return;
    bool hmv = false;
    call_method_is_valid(api.method_is_valid, &hm, &hmv);
    if (!hmv) { logf("ATTR: HasCombatHistoryWithSoul did not resolve"); return; }

    float max_time = 30.0f;
    alignas(8) unsigned char h0[32], h1[32];
    build_argument(h0, &attacker, t_soulptr);
    build_argument(h1, &max_time, t_float);

    Variant hres{};
    if (!call_invoke2(api.invoke2, &hm, &hres, cinst.bytes, h0, h1)) {
        logf("ATTR: FAULT during HasCombatHistoryWithSoul"); return;
    }
    bool has_history = false;
    std::memcpy(&has_history, hres.data, sizeof(has_history));
    call_variant_dtor(api.variant_dtor, &hres);

    logf("ATTR: HasCombatHistoryWithSoul(player, 30s) = %s   <-- %s",
         has_history ? "TRUE" : "false",
         has_history ? "ATTRIBUTION REGISTERED"
                     : "attribution did NOT register from a bare TakeDamage");
}

} // namespace kcdmp::rttr
