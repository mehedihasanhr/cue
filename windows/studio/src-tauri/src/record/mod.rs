//! Recording a take: the picture, the sound and the telemetry, all on one clock, into a
//! `.cuerec` package.

// Much of the recorder only runs on Windows; elsewhere it is built but never called.
#![cfg_attr(not(windows), allow(dead_code))]
pub mod audio;
pub mod clock;
pub mod package;
pub mod screen;
pub mod session;
pub mod telemetry;
