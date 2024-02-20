#include "init.h"
#include "io/logger.h"

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

  // TODO: handle user space, do some stuff

  while (1);
}
