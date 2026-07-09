#include "LastError.h"

namespace sn
{
namespace
{
// One string per thread. thread_local guarantees each Core call chain sees its own slot even when
// multiple emulators run on different threads (e.g. background transcoding, tests). The buffer
// is intentionally never cleared on read — a UI layer that shows the error can call
// sn_last_error() twice for the same failure without racing against a "reset on read" idiom.
thread_local std::string g_lastError;
}

void setLastError(const std::string& msg)
{
    g_lastError = msg;
}

const char* getLastErrorCStr()
{
    return g_lastError.c_str();
}
}
