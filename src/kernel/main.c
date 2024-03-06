#include "init.h"
#include "logger.h"

#include "dev/stds/pci.h"

#include "dev/device.h"
#include "dev/keyboard.h"
#include "dev/timer.h"

/* imported virtual addresses, see linker script */
extern unsigned char environment[4096]; // configuration, UTF-8 text key=value pairs

// Entry point, called by BOOTBOOT Loader
void _start() {
  Status status = init_kernel();

  if (status == KERNEL_ERROR) {
    // TODO: handle kernel panic
    kernel_error("Initialization failed: (%e) %s\n", status, error_str);
    while (1);    
  }
  else if (status == KERNEL_PANIC) {
    while (1);
  }

  kernel_msg("Kernel initialized successfuly\n");
  // TODO: handle user space, do some stuff

  while (1);
}
