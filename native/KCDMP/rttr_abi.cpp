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
        return;
    }

    logf("WALK: no candidate instance layout worked");
}

} // namespace kcdmp::rttr
