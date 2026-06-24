using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class OskarKeyboardHook {
    public const int WH_KEYBOARD_LL = 13;
    public const int WM_KEYDOWN = 0x0100;
    public const int VK_F13 = 0x7C;
    public const int VK_F14 = 0x7D;
    public const int VK_F15 = 0x7E;
    private static LowLevelKeyboardProc proc = HookCallback;
    private static IntPtr hookID = IntPtr.Zero;
    private static Action<int> callback;

    public static void Run(Action<int> onKeyPressed) {
        callback = onKeyPressed;
        Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) {
            e.Cancel = true;
            Application.Exit();
        };
        hookID = SetHook(proc);
        if (hookID == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetWindowsHookEx failed");
        }
        try {
            Application.Run();
        } finally {
            if (hookID != IntPtr.Zero) {
                UnhookWindowsHookEx(hookID);
                hookID = IntPtr.Zero;
            }
        }
    }

    private static IntPtr SetHook(LowLevelKeyboardProc proc) {
        using (Process curProcess = Process.GetCurrentProcess())
        using (ProcessModule curModule = curProcess.MainModule) {
            return SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(curModule.ModuleName), 0);
        }
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && wParam == (IntPtr)WM_KEYDOWN) {
            int vkCode = Marshal.ReadInt32(lParam);
            if (vkCode == VK_F13 || vkCode == VK_F14 || vkCode == VK_F15) {
                if (callback != null) { callback.Invoke(vkCode); }
            }
        }
        return CallNextHookEx(hookID, nCode, wParam, lParam);
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
}
