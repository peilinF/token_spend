#include "shim.h"

// The target is a module wrapper around Apple's CommonCrypto headers. Keep a
// translation unit so SwiftPM emits the target object on clean builds.
