// The ONNX Runtime C API is header-only from our side: the implementation is
// already linked into the binary by moonshine-swift, whose static library
// embeds ORT 1.23.0 and exports its C entry points. This file exists only
// because SwiftPM requires a C target to have at least one source file.
#include "onnxruntime_c_api.h"
