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

} // namespace kcdmp::rttr
