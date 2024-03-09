# C FFI Library

<details>
    <summary>Allowed type for arguments:</summary>

- `int`: signed integers
- `double`: high-precision floating point number
- `bool`: boolean value
- `int32_t`: 32 bit signed integer
- `char`: 1 character
- `size_t`: unsigned integer type used to represent the size of objects in bytes
- `intptr_t`: an integer value that is safe to convert to a pointer
- `uint16_t`: unsigned 16 bit integer
- `uint32_t`: unsigned 32 bit integer
- `uint64_t`: unsigned 64 bit integer
- `char*`: string (i.e. a null terminated array of characters, starting at a pointer to a char)
- `Tcl_Obj*`: a pointer to a Tcl object
- `<above>*`: pointers to anything above

</details>

## C namespace

- `create {}`: creates and returns a new C FFI interface

---
CC-BY-SA 2023 Arcade Wise
(We can change the license if y'all want, I just wanted to avoid copyright issues)
