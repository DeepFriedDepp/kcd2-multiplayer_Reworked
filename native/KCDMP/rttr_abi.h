#pragma once
// Hand-modelled ABI for the game's RTTR fork.
//
// WHY NOT UPSTREAM HEADERS: this is a Warhorse fork, not stock RTTR.
// type::get_by_name takes std::basic_string_view where upstream takes
// rttr::string_view, and rttr::argument is 24 bytes here against upstream's 16.
// Vendoring upstream headers would compile cleanly and corrupt memory at
// runtime, which is the worst possible failure mode.
//
// EVERYTHING BELOW WAS READ OUT OF THE BINARY, not assumed. Prologues were
// decoded from CrySystem.dll; each claim carries the evidence that produced it.
// Anything still uncertain is marked GUESS and must not be relied on.
//
// Calling convention, established from the disassembly:
//
//   static fn returning a class in memory : RCX = &ret,  RDX.. = params
//   member fn returning a class in memory : RCX = this,  RDX = &ret, R8.. = params
//   member fn returning a scalar          : RCX = this,  RDX.. = params
//   class-typed params are ALWAYS passed by address
//
// Note the this/sret ordering flips between the static and member cases. That
// is MSVC's rule -- `this` occupies the first slot and the return buffer is
// inserted after it -- and it is why every entry point below is declared as a
// plain function with the hidden pointers spelled out, rather than as something
// that looks like a method. Letting the compiler infer them would silently
// produce the static ordering for member calls.

#include <windows.h>
#include <cstdint>
#include <cstring>
#include <string_view>

namespace kcdmp::rttr {

// rttr::type -- a single pointer.
// Evidence: type::is_valid does `mov rax,[rbx]` straight off `this`, and a
// whole family of pointer-taking wrapper constructors collapse onto one thunk
// at RVA 0x4F530, which is what "store one pointer" compiles to.
struct Type { void* data; };

// rttr::method, rttr::property -- same single-pointer shape, same evidence.
struct Method   { void* data; };
struct Property { void* data; };

// rttr::variant -- 24 bytes: { char data[16]; void* policy; }.
// Evidence: variant::variant() writes the policy function pointer to
// [this+0x10]; ~variant() loads [this+0x10] and tail-calls it with op=0; the
// copy constructor copies [src+0x10] to [dst+0x10] and calls it with op=1.
// The 16-byte payload matches std::_Align_type<double,16> seen throughout the
// exported variant_data_policy signatures.
struct alignas(8) Variant {
    unsigned char data[16];
    void*         policy;
};
static_assert(sizeof(Variant) == 24, "variant must be 24 bytes");

// rttr::argument -- 24 bytes, NOT upstream's 16.
// Evidence: argument::argument() zeroes [this+0] and [this+8], then calls a
// constructor for a member at [this+0x10]; argument::get_type returns
// [this+0x10]. The middle eight bytes are not yet identified.
// GUESS: zero-initialising the middle word is what the default constructor
// does, so it is at worst consistent with an empty argument.
struct alignas(8) Argument {
    const void* data;
    uint64_t    unknown8;   // zeroed by the default ctor; purpose unidentified
    Type        type;
};
static_assert(sizeof(Argument) == 24, "argument must be 24 bytes");

// rttr::instance -- type sits at offset 0, unlike argument.
// Evidence: instance::get_type does `mov rax,[rbx]`, i.e. offset 0. The default
// ctor fills +0 and +8 from two separate calls and then zeroes a third field,
// which is consistent with { type; type; void* }.
//
// GUESS: the field order beyond +0 is inferred, not proven. Rather than decode
// further, InstanceBuf below lets the caller try each candidate layout and keep
// whichever one produces a value that matches the HTTP API's ground truth.
enum class InstanceLayout {
    TypeTypeData,   // { type, derived_type, void* }  -- 24 bytes
    TypeData,       // { type, void* }                -- 16 bytes
    Count
};

inline const char* layout_name(InstanceLayout l) {
    switch (l) {
        case InstanceLayout::TypeTypeData: return "{type,type,data}/24";
        case InstanceLayout::TypeData:     return "{type,data}/16";
        default:                           return "?";
    }
}

// Oversized and zeroed, so a layout that is smaller than the callee expects
// still points at readable memory rather than at the stack frame behind it.
struct alignas(8) InstanceBuf {
    unsigned char bytes[32];

    void build(InstanceLayout layout, Type t, const void* obj) {
        std::memset(bytes, 0, sizeof(bytes));
        auto* slot = reinterpret_cast<void**>(bytes);
        switch (layout) {
            case InstanceLayout::TypeTypeData:
                slot[0] = t.data;
                slot[1] = t.data;
                slot[2] = const_cast<void*>(obj);
                break;
            case InstanceLayout::TypeData:
                slot[0] = t.data;
                slot[1] = const_cast<void*>(obj);
                break;
            default:
                break;
        }
    }
};

// ---------------------------------------------------------------------------
// Entry points. Hidden pointers are explicit; see the convention note above.
// ---------------------------------------------------------------------------

// static rttr::type rttr::type::get_by_name(std::string_view)
using GetByName = void* (*)(Type* ret, const std::string_view* name);

// bool rttr::type::is_valid() const
using TypeIsValid = bool (*)(const Type* self);

// rttr::method rttr::type::get_method(std::string_view) const
using GetMethod = void* (*)(const Type* self, Method* ret, const std::string_view* name);

// rttr::property rttr::type::get_property(std::string_view) const
using GetProperty = void* (*)(const Type* self, Property* ret, const std::string_view* name);

// bool rttr::method::is_valid() const
using MethodIsValid = bool (*)(const Method* self);

// std::string_view rttr::method::get_name() const
using MethodGetName = void* (*)(const Method* self, std::string_view* ret);

// std::string_view rttr::method::get_signature() const
using MethodGetSignature = void* (*)(const Method* self, std::string_view* ret);

// bool rttr::property::is_valid() const
using PropertyIsValid = bool (*)(const Property* self);

// rttr::variant rttr::type::get_property_value(std::string_view, rttr::instance) const
// Member returning a class in memory: RCX=this, RDX=&ret, R8=&name, R9=&instance.
using GetPropertyValue = void* (*)(const Type* self, Variant* ret,
                                   const std::string_view* name, const void* instance);

// rttr::variant::~variant()
using VariantDtor = void (*)(Variant* self);

// bool rttr::variant::is_valid() const
//
// This is how "invoke did not crash" is told apart from "invoke did something".
// rttr returns an INVALID variant when it cannot match the arguments to the
// method's signature -- no exception, no fault, just a call that quietly did
// nothing. Trusting the absence of a fault is precisely the mistake the Lua
// investigation made with pcall.
using VariantIsValid = bool (*)(const Variant* self);

// static wh::shared::C_GameInterface* wh::shared::C_GameInterface::GetWritableInstance()
// Exported from Shared.dll. No hidden pointers, no class params -- result in RAX.
using GetGameInterface = void* (*)();

// rttr::enumeration -- another single-pointer wrapper.
struct Enumeration { void* data; };

// rttr::enumeration rttr::type::get_enumeration() const
using GetEnumeration = void* (*)(const Type* self, Enumeration* ret);

// rttr::variant rttr::enumeration::name_to_value(std::string_view) const
using NameToValue = void* (*)(const Enumeration* self, Variant* ret, const std::string_view* name);

// rttr::argument::argument(const rttr::variant&)
//
// This constructor is the way out of the argument-layout problem. Rather than
// guessing which of argument's three fields holds what, build one from a
// variant whose contents are already known and read the bytes back -- the
// exported constructor is its own oracle.
using ArgumentFromVariant = void* (*)(void* self, const Variant* v);

// rttr::variant rttr::method::invoke(rttr::instance, rttr::argument) const
using Invoke1 = void* (*)(const Method* self, Variant* ret, const void* instance, const void* arg);

// ...invoke(instance, argument, argument, argument) const -- three arguments.
// Stack arguments beyond the fourth register slot are passed by address like
// the rest; the compiler handles that from this declaration.
using Invoke3 = void* (*)(const Method* self, Variant* ret, const void* instance,
                          const void* a0, const void* a1, const void* a2);
using Invoke2 = void* (*)(const Method* self, Variant* ret, const void* instance,
                          const void* a0, const void* a1);

// --- associative container traversal ---------------------------------------
//
// SoulsByGuid is an unordered_map<CryGUID, C_Soul*>. rttr exposes it through
// variant_associative_view, which also has find(argument) -- the eventual
// SharedSoulGuid -> Soul* lookup the shared-world design needs.
//
// These types hold real state: the view's destructor reserves 0xD0 of stack and
// begin() reads from view+0x30, so the sizes are NOT the single-pointer shape
// the other wrappers had. Rather than guess, callers over-allocate. Writing
// into a return buffer bigger than the object is always safe; the only failure
// mode would be a buffer smaller than the object, which these are not.
constexpr size_t kViewBufBytes = 512;
constexpr size_t kIterBufBytes = 256;
constexpr size_t kPairBufBytes = 128;   // std::pair<variant,variant> is 48

// rttr::variant_associative_view rttr::variant::create_associative_view() const
using CreateAssocView = void* (*)(const Variant* self, void* ret);
using ViewIsValid     = bool  (*)(const void* view);
using ViewGetSize     = uint64_t (*)(const void* view);
using ViewBegin       = void* (*)(void* view, void* ret_iterator);
using ViewDtor        = void  (*)(void* view);
// std::pair<variant,variant> iterator::operator*()
using IterDeref       = void* (*)(void* iter, void* ret_pair);
using IterDtor        = void  (*)(void* iter);
using ViewEnd         = void* (*)(void* view, void* ret_iterator);
using IterPreInc      = void* (*)(void* iter);                       // ++it
using IterNotEqual    = bool  (*)(const void* iter, const void* other);

struct Api {
    GetByName          get_by_name          = nullptr;
    TypeIsValid        type_is_valid        = nullptr;
    GetMethod          get_method           = nullptr;
    GetProperty        get_property         = nullptr;
    MethodIsValid      method_is_valid      = nullptr;
    MethodGetName      method_get_name      = nullptr;
    MethodGetSignature method_get_signature = nullptr;
    PropertyIsValid    property_is_valid    = nullptr;
    GetPropertyValue   get_property_value   = nullptr;
    VariantDtor        variant_dtor         = nullptr;
    VariantIsValid     variant_is_valid     = nullptr;
    GetGameInterface   game_interface       = nullptr;
    GetEnumeration     get_enumeration      = nullptr;
    NameToValue        name_to_value        = nullptr;
    ArgumentFromVariant argument_from_variant = nullptr;
    Invoke1            invoke1              = nullptr;
    Invoke3            invoke3              = nullptr;
    Invoke2            invoke2              = nullptr;
    CreateAssocView    create_assoc_view    = nullptr;
    ViewIsValid        view_is_valid        = nullptr;
    ViewGetSize        view_get_size        = nullptr;
    ViewBegin          view_begin           = nullptr;
    ViewDtor           view_dtor            = nullptr;
    IterDeref          iter_deref           = nullptr;
    IterDtor           iter_dtor            = nullptr;
    ViewEnd            view_end             = nullptr;
    IterPreInc         iter_preinc          = nullptr;
    IterNotEqual       iter_not_equal       = nullptr;

    bool complete() const {
        return get_by_name && type_is_valid && get_method && get_property &&
               method_is_valid && method_get_name && method_get_signature &&
               property_is_valid && get_property_value && variant_dtor && variant_is_valid &&
               game_interface && get_enumeration && name_to_value &&
               argument_from_variant && invoke1 && invoke3 && invoke2 &&
               create_assoc_view && view_is_valid && view_get_size &&
               view_begin && view_dtor && iter_deref && iter_dtor &&
               view_end && iter_preinc && iter_not_equal;
    }
};

// Build an argument for a raw value. Recipe proven against GetState: both
// leading fields point at the value, the third is the type handle. `value`
// must outlive the call -- the argument refers to it, it does not copy.
inline void build_argument(void* buf32, const void* value, Type type) {
    std::memset(buf32, 0, 32);
    auto* w = reinterpret_cast<const void**>(buf32);
    w[0] = value;
    w[1] = value;
    w[2] = type.data;
}

bool resolve(Api& api);
bool validate();
void walk_to_soul();
void probe_invoke();
void probe_take_damage();

// Pull one soul out of SoulList::SoulsByGuid that is not the player, and
// attribute damage to the player. This is the attribution test that needs two
// distinct souls, and the map traversal it requires is the same machinery the
// plugin needs for SharedSoulGuid -> Soul* lookup.
void probe_attribution();

// Attach a ghost's orphan faction node to a real faction, by copying the
// faction a donor NPC already belongs to. Reads two GUIDs (ghost, donor) from
// kcdmp-faction.txt beside the DLL; absent means do nothing.
//
// Copying a donor's parent avoids having to construct a std::string argument
// for C_FactionManager::GetFaction -- NPCFaction::Parent is already a reflected
// shared_ptr<C_Faction>, so the value can be read out and handed straight to
// SetParent without building any container type by hand.
void probe_faction();

/// Dump the innards of the rttr method wrapper for CombatSoul::TakeDamage,
/// looking for a pointer to the real member function. TakeDamage is not
/// exported, so this is the route to an address we can detour for the OUTBOUND
/// direction -- detecting a hit our own player landed. Read-only.
void probe_method_wrapper();

// ---------------------------------------------------------------------------
// Outbound detection (WO-4).
//
// Detects that a nearby NPC lost health and reports it, so peers can apply the
// same hit. Sampling rather than hooking: CombatSoul::TakeDamage is not
// exported, and recovering its address from the rttr method wrapper means
// disassembling for a call target -- an offset that breaks silently on the next
// patch. Polling costs a few reflected reads per tick and cannot break that way.
//
// Consequences, accepted deliberately:
//   - a hit is reported one sample late, up to ~60 ms
//   - several fast hits inside one interval merge into one larger report
//   - damage from ANY source is reported, including NPC-vs-NPC, which keeps
//     the shared world consistent rather than only mirroring the player
//   - damage this client applied because a peer told it to is excluded, or the
//     two clients would echo the same hit forever
// ---------------------------------------------------------------------------

/// Sample tracked souls and report drops. Call from the main thread each tick;
/// it rate-limits internally.
void sample_health(void (*on_hit)(const unsigned char guid[16], float health_delta,
                                  bool died));

/// Tell the sampler that a health change was caused by an inbound packet, so it
/// is not reported back out.
void note_remote_damage(const unsigned char guid[16], float health_delta);

// ---------------------------------------------------------------------------
// Combat application (WO-4). These are what the network layer ultimately calls.
//
// MUST be called on the game's main thread -- post them through
// main_thread::post/run_sync. They touch the combat system, and the injected
// thread races it.
//
// `guid` is a SharedSoulGuid in the game's in-memory byte order, i.e. the raw
// 16 bytes of the SoulsByGuid key, not the text form.
// ---------------------------------------------------------------------------

/// Resolve a soul pointer from its SharedSoulGuid. Null if not loaded here --
/// a legitimate outcome, since the peer may be somewhere this client has not
/// streamed in.
void* find_soul_by_guid(const unsigned char guid[16]);

/// Apply damage attributed to no one. Returns false if the soul is not loaded.
bool apply_damage(const unsigned char guid[16], float stamina, float health,
                  bool suppress_hit_reaction);

/// Kill a soul, idempotently: already dead is success, not an error. Death is
/// its own operation rather than a consequence of health hitting zero, so two
/// clients cannot disagree about who is alive.
bool apply_death(const unsigned char guid[16]);

// void wh::rpgmodule::C_FactionBase::SetParent(std::shared_ptr<C_Faction>)
// Exported from RPGModule.dll. Virtual (UEAA), so calling the exported address
// bypasses dispatch -- acceptable only because the result is verified by
// reading Parent back afterwards.
using FactionSetParent = void (*)(void* self, const void* shared_ptr_faction);

} // namespace kcdmp::rttr
