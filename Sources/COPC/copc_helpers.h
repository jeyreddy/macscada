/// copc_helpers.h — Swift-friendly wrappers for UA_TYPES[] array access.
///
/// Swift imports the C global `const UA_DataType UA_TYPES[228]` as a large
/// tuple, which cannot be subscripted at runtime.  These static-inline
/// functions let the C compiler do the subscripting and return a pointer
/// that Swift can consume as `UnsafePointer<UA_DataType>`.
#pragma once
#include <open62541/client.h>

static inline const UA_DataType* copc_type_boolean(void) { return &UA_TYPES[UA_TYPES_BOOLEAN]; }
static inline const UA_DataType* copc_type_int32(void)   { return &UA_TYPES[UA_TYPES_INT32];   }
static inline const UA_DataType* copc_type_uint32(void)  { return &UA_TYPES[UA_TYPES_UINT32];  }
static inline const UA_DataType* copc_type_float(void)   { return &UA_TYPES[UA_TYPES_FLOAT];   }
static inline const UA_DataType* copc_type_double(void)  { return &UA_TYPES[UA_TYPES_DOUBLE];  }
