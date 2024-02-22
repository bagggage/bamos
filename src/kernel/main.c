#include "init.h"
#include "io/logger.h"
#include "dev/device.h"
#include "dev/keyboard.h"

/* imported virtual addresses, see linker script */
extern unsigned char environment[4096]; // configuration, UTF-8 text key=value pairs

// Entry point, called by BOOTBOOT Loader
void _start() {
  Status status = init_kernel();

  if (status != KERNEL_OK) {
    // TODO: handle kernel panic
    kernel_error("Initialization failed: %e", status);
    while (1);
  }

  KeyboardDevice* keyboard = dev_pool.data[DEV_KEYBOARD_ID];

  while (1) {
    char c = scan_code_to_ascii(keyboard->interface.get_scan_code());
    raw_putc(c);
  }

  // TODO: handle user space, do some stuff

  while (1);
}
