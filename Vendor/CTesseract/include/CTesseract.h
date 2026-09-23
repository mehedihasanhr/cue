/*
 * Tesseract's C API, made safe to import as a Clang module.
 *
 * capi.h does `#ifndef BOOL / #define BOOL int`. Objective-C's BOOL is a typedef
 * rather than a macro, so that #define succeeds — and would then be exported from
 * this module and redefine BOOL for anything that imports it, AppKit included.
 * Every declaration below has already been expanded by the time we get here, so
 * dropping the macros costs nothing: Swift sees Int32 returns and compares them
 * against 0, and AppKit's BOOL stays the typedef it always was.
 *
 * Leptonica's headers are deliberately absent. capi.h only forward-declares
 * `struct Pix`, and Klik never constructs one — it hands Tesseract a raw buffer.
 */
#pragma once

#include <tesseract/capi.h>

#undef BOOL
#undef TRUE
#undef FALSE
