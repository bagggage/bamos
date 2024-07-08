#pragma once

#define _UTS_NAME_STR_LENGTH 65

struct utsname {
    char sysname[_UTS_NAME_STR_LENGTH];  /* Operating system name (e.g., "Linux") */
    char nodename[_UTS_NAME_STR_LENGTH]; /* Name within communications network
                                            to which the node is attached, if any */
    char release[_UTS_NAME_STR_LENGTH];  /* Operating system release
                                            (e.g., "2.6.28") */
    char version[_UTS_NAME_STR_LENGTH];  /* Operating system version */
    char machine[_UTS_NAME_STR_LENGTH];  /* Hardware type identifier */
};