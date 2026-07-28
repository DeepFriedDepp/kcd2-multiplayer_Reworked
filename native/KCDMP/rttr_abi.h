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

// rttr::instance -- type sits at offset 0 here, unlike argument.
// Evidence: instance::get_type does `mov rax,[rbx]`, i.e. offset 0.
// GUESS: the remaining layout is unverified; do not construct one of these
// until its constructors have been decoded the way argument's were.
struct alignas(8) Instance {
    Type        type;
    const void* data;
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

struct Api {
    GetByName          get_by_name          = nullptr;
    TypeIsValid        type_is_valid        = nullptr;
    GetMethod          get_method           = nullptr;
    GetProperty        get_property         = nullptr;
    MethodIsValid      method_is_valid      = nullptr;
    MethodGetName      method_get_name      = nullptr;
    MethodGetSignature method_get_signature = nullptr;
    PropertyIsValid    property_is_valid    = nullptr;

    bool complete() const {
        return get_by_name && type_is_valid && get_method && get_property &&
               method_is_valid && method_get_name && method_get_signature &&
               property_is_valid;
    }
};

bool resolve(Api& api);

} // namespace kcdmp::rttr
