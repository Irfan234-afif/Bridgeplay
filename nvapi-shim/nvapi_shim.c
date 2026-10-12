/*
 * nvapi64.dll in front of Apple's NvAPI (Game Porting Toolkit), which reports driver
 * 561.09 (r560_88) and nothing newer. Games and engines that want a newer NVIDIA driver
 * then warn about an out-of-date driver or hide DLSS (Deadlock's Source 2 keeps a list of
 * minimum driver versions). Every call goes to Apple's nvapi, loaded under its internal
 * name nvapi.dll (the builtin WineCX links to the GPTK), and only the driver version and
 * branch it answers are replaced: 595.41 / r595_00 by default, or NOTPROTON_NVAPI_DRIVER
 * (e.g. 59541) when set.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int NvAPI_Status;
typedef void *(__cdecl *query_interface_fn)(unsigned int);

#define ID_GET_DISPLAY_DRIVER_VERSION 0xf951a4d1u
#define ID_SYS_GET_DRIVER_AND_BRANCH  0x2926aaadu
#define ID_SYS_GET_DISPLAY_DRIVER_INFO 0x721facebu

typedef struct
{
    unsigned int version;
    unsigned int drvVersion;
    unsigned int bldChangeListNum;
    char szBuildBranchString[64];
    char szAdapterString[64];
} NV_DISPLAY_DRIVER_VERSION;

/* NV_DISPLAY_DRIVER_INFO_V1/V2 start with version, driverVersion, szBuildBranch. */
typedef struct
{
    unsigned int version;
    unsigned int driverVersion;
    char szBuildBranch[64];
} NV_DISPLAY_DRIVER_INFO_HEAD;

static INIT_ONCE init_once = INIT_ONCE_STATIC_INIT;
static query_interface_fn apple_query_interface;
static unsigned int driver_version = 59541;
static char driver_branch[64];

static NvAPI_Status (__cdecl *apple_get_display_driver_version)(void *, NV_DISPLAY_DRIVER_VERSION *);
static NvAPI_Status (__cdecl *apple_sys_get_driver_and_branch)(unsigned int *, char *);
static NvAPI_Status (__cdecl *apple_sys_get_display_driver_info)(NV_DISPLAY_DRIVER_INFO_HEAD *);

static BOOL CALLBACK load_apple( INIT_ONCE *once, void *param, void **context )
{
    char value[32];
    HMODULE apple;
    DWORD len = GetEnvironmentVariableA( "NOTPROTON_NVAPI_DRIVER", value, sizeof(value) );

    if (len && len < sizeof(value))
    {
        unsigned long parsed = strtoul( value, NULL, 10 );
        if (parsed >= 10000 && parsed <= 99999) driver_version = (unsigned int)parsed;
    }
    snprintf( driver_branch, sizeof(driver_branch), "r%u_00", driver_version / 100 );

    if (!(apple = LoadLibraryW( L"nvapi.dll" ))) return TRUE;
    apple_query_interface = (query_interface_fn)(void *)GetProcAddress( apple, "nvapi_QueryInterface" );
    return TRUE;
}

static void set_branch( char *dst )
{
    memcpy( dst, driver_branch, sizeof(driver_branch) );
}

static NvAPI_Status __cdecl get_display_driver_version( void *display, NV_DISPLAY_DRIVER_VERSION *info )
{
    NvAPI_Status status = apple_get_display_driver_version( display, info );
    if (!status && info)
    {
        info->drvVersion = driver_version;
        set_branch( info->szBuildBranchString );
    }
    return status;
}

static NvAPI_Status __cdecl sys_get_driver_and_branch( unsigned int *version, char *branch )
{
    NvAPI_Status status = apple_sys_get_driver_and_branch( version, branch );
    if (!status)
    {
        if (version) *version = driver_version;
        if (branch) set_branch( branch );
    }
    return status;
}

static NvAPI_Status __cdecl sys_get_display_driver_info( NV_DISPLAY_DRIVER_INFO_HEAD *info )
{
    NvAPI_Status status = apple_sys_get_display_driver_info( info );
    if (!status && info)
    {
        info->driverVersion = driver_version;
        set_branch( info->szBuildBranch );
    }
    return status;
}

void * __cdecl nvapi_QueryInterface( unsigned int id )
{
    void *fn;

    InitOnceExecuteOnce( &init_once, load_apple, NULL, NULL );
    if (!apple_query_interface || !(fn = apple_query_interface( id ))) return NULL;
    switch (id)
    {
    case ID_GET_DISPLAY_DRIVER_VERSION:
        apple_get_display_driver_version = fn;
        return (void *)get_display_driver_version;
    case ID_SYS_GET_DRIVER_AND_BRANCH:
        apple_sys_get_driver_and_branch = fn;
        return (void *)sys_get_driver_and_branch;
    case ID_SYS_GET_DISPLAY_DRIVER_INFO:
        apple_sys_get_display_driver_info = fn;
        return (void *)sys_get_display_driver_info;
    }
    return fn;
}

/* nvapi_Direct_GetMethod is an export forwarder to nvapi.dll (nvapi_shim.def). */
