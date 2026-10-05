/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Diagnostics, linked only with LOKJS_TRACE=1: wraps a few LibreOffice entry points with the
 * linker's --wrap option (no change to LibreOffice itself) and reports to the browser console.
 */
#include <emscripten.h>

int __real_soffice_main(void);
int __wrap_soffice_main(void)
{
    EM_ASM({ console.log('lokjs-trace: soffice_main() start'); });
    int ret = __real_soffice_main();
    EM_ASM({ console.error('lokjs-trace: soffice_main() returned ' + $0); }, ret);
    return ret;
}

/* Application::Execute() — enters the main loop; does not return on Emscripten. */
void __real__ZN11Application7ExecuteEv(void);
void __wrap__ZN11Application7ExecuteEv(void)
{
    EM_ASM({ console.log('lokjs-trace: Application::Execute()'); });
    __real__ZN11Application7ExecuteEv();
}
