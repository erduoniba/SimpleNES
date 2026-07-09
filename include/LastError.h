// Small internal helper for surfacing the last error message from the core layer up to the C API
// caller. Kept as thread_local so callers on different threads don't race — and so tests that
// spin up multiple emulators in parallel each see their own last error.
//
// Not part of the public C API header — hosts talk to it exclusively through sn_last_error().

#ifndef SN_LAST_ERROR_H
#define SN_LAST_ERROR_H

#include <string>

namespace sn
{
// Overwrite the current thread's last-error message. Passing an empty string clears it.
void setLastError(const std::string& msg);

// Read the current thread's last-error message. Never returns NULL — an empty string means
// "no error since the last successful call cleared it."
const char* getLastErrorCStr();
}

#endif // SN_LAST_ERROR_H
