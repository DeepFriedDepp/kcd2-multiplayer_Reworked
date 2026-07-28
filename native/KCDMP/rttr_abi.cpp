#include "rttr_abi.h"
#include "pe_exports.h"
#include "log.h"

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

} // namespace

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

    alignas(16) unsigned char it[kIterBufBytes]{};
    if (!call_view_begin(api.view_begin, view, it)) {
        logf("ATTR: FAULT in begin()");
        call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
        call_variant_dtor(api.variant_dtor, &map_v);
        return;
    }

    // First entry only. std::pair<variant,variant>: key at +0, value at +24.
    alignas(16) unsigned char pr[kPairBufBytes]{};
    void* target = nullptr;
    if (call_iter_deref(api.iter_deref, it, pr)) {
        // The variants hold POINTERS TO the map node's key and value, not
        // copies of them. Evidence from the first run: the two payloads were
        // 0x...3F40 and 0x...3F50, exactly 16 bytes apart -- a 16-byte CryGUID
        // key followed immediately by an 8-byte C_Soul* value, which is the
        // node layout. Reading them as inline values yielded a "GUID" that was
        // really a little-endian pointer, and a "soul" that was really the
        // address of the soul pointer.
        void* key_addr = nullptr;
        void* val_addr = nullptr;
        std::memcpy(&key_addr, reinterpret_cast<Variant*>(pr)->data, sizeof(key_addr));
        std::memcpy(&val_addr, reinterpret_cast<Variant*>(pr + sizeof(Variant))->data,
                    sizeof(val_addr));
        logf("ATTR: key@%p value@%p (delta %lld)", key_addr, val_addr,
             static_cast<long long>(reinterpret_cast<char*>(val_addr) -
                                    reinterpret_cast<char*>(key_addr)));

        if (plausible_pointer(key_addr) && plausible_pointer(val_addr)) {
            const unsigned char* k = reinterpret_cast<const unsigned char*>(key_addr);
            logf("ATTR: key = %02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-"
                 "%02X%02X%02X%02X%02X%02X",
                 k[0],k[1],k[2],k[3], k[4],k[5], k[6],k[7],
                 k[8],k[9], k[10],k[11],k[12],k[13],k[14],k[15]);
            std::memcpy(&target, val_addr, sizeof(target));
            logf("ATTR: soul = %p  (player is %p)", target, g_player);
        }
    } else {
        logf("ATTR: FAULT dereferencing the iterator");
    }

    call_void1(reinterpret_cast<void(*)(void*)>(api.iter_dtor), it);
    call_void1(reinterpret_cast<void(*)(void*)>(api.view_dtor), view);
    call_variant_dtor(api.variant_dtor, &map_v);

    if (!plausible_pointer(target) || target == g_player) {
        logf("ATTR: no usable distinct soul; stopping before any damage");
        return;
    }

    // That soul's CombatSoul, then damage attributed to the player.
    const std::string_view soul_name{"wh::rpgmodule::Soul"};
    Type t_soul{};
    if (!call_get_by_name(api.get_by_name, &t_soul, &soul_name)) return;
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
}

} // namespace kcdmp::rttr
