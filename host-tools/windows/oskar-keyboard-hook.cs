using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class OskarKeyboardHook {
    private const int WM_INPUT = 0x00FF;
    private const int RIDEV_INPUTSINK = 0x00000100;
    private const int RID_INPUT = 0x10000003;
    private const int RIDI_DEVICENAME = 0x20000007;
    private const int RIM_TYPEHID = 2;
    private const int OSKAR_USAGE_PAGE = 0xFF00;
    private const int OSKAR_USAGE = 0x0001;
    private const string OSKAR_VID = "VID_1CED";
    private const string OSKAR_PID = "PID_C0FE";

    private static Action<int> callback;
    private static OskarRawInputForm form;

    public static void Run(Action<int> onButtonPressed) {
        callback = onButtonPressed;
        Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) {
            e.Cancel = true;
            Application.Exit();
        };

        form = new OskarRawInputForm();
        form.Register();
        Application.Run(form);
    }

    private static void DispatchButton(int buttonId) {
        if (callback != null) { callback.Invoke(buttonId); }
    }

    private class OskarRawInputForm : Form {
        private readonly Dictionary<IntPtr, bool> deviceCache = new Dictionary<IntPtr, bool>();

        public OskarRawInputForm() {
            ShowInTaskbar = false;
            WindowState = FormWindowState.Minimized;
        }

        public void Register() {
            RAWINPUTDEVICE[] devices = new RAWINPUTDEVICE[] {
                new RAWINPUTDEVICE {
                    usUsagePage = OSKAR_USAGE_PAGE,
                    usUsage = OSKAR_USAGE,
                    dwFlags = RIDEV_INPUTSINK,
                    hwndTarget = Handle,
                },
            };

            if (!RegisterRawInputDevices(devices, (uint)devices.Length, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "RegisterRawInputDevices failed");
            }
        }

        protected override void SetVisibleCore(bool value) {
            base.SetVisibleCore(false);
        }

        protected override void WndProc(ref Message message) {
            if (message.Msg == WM_INPUT) {
                HandleRawInput(message.LParam);
            }
            base.WndProc(ref message);
        }

        private void HandleRawInput(IntPtr rawInputHandle) {
            uint size = 0;
            GetRawInputData(rawInputHandle, RID_INPUT, IntPtr.Zero, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER)));
            if (size == 0) {
                return;
            }

            IntPtr buffer = Marshal.AllocHGlobal((int)size);
            try {
                uint read = GetRawInputData(rawInputHandle, RID_INPUT, buffer, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                if (read != size) {
                    return;
                }

                RAWINPUTHEADER header = (RAWINPUTHEADER)Marshal.PtrToStructure(buffer, typeof(RAWINPUTHEADER));
                if (header.dwType != RIM_TYPEHID || !IsOskarDevice(header.hDevice)) {
                    return;
                }

                int headerSize = Marshal.SizeOf(typeof(RAWINPUTHEADER));
                int hidSize = Marshal.ReadInt32(buffer, headerSize);
                int hidCount = Marshal.ReadInt32(buffer, headerSize + 4);
                int dataOffset = headerSize + 8;
                if (hidSize < 2 || hidCount <= 0) {
                    return;
                }

                for (int index = 0; index < hidCount; index++) {
                    int reportOffset = dataOffset + (index * hidSize);
                    int payloadOffset = reportOffset;
                    if (hidSize >= 3 && Marshal.ReadByte(buffer, reportOffset) == 0) {
                        payloadOffset = reportOffset + 1;
                    }

                    int buttonId = Marshal.ReadByte(buffer, payloadOffset);
                    int pressed = Marshal.ReadByte(buffer, payloadOffset + 1);
                    if (pressed == 1 && buttonId >= 1 && buttonId <= 3) {
                        DispatchButton(buttonId);
                    }
                }
            } finally {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private bool IsOskarDevice(IntPtr deviceHandle) {
            bool cached;
            if (deviceCache.TryGetValue(deviceHandle, out cached)) {
                return cached;
            }

            uint charCount = 0;
            GetRawInputDeviceInfo(deviceHandle, RIDI_DEVICENAME, IntPtr.Zero, ref charCount);
            if (charCount == 0) {
                deviceCache[deviceHandle] = false;
                return false;
            }

            StringBuilder name = new StringBuilder((int)charCount);
            uint result = GetRawInputDeviceInfo(deviceHandle, RIDI_DEVICENAME, name, ref charCount);
            bool isOskar = result > 0 &&
                name.ToString().IndexOf(OSKAR_VID, StringComparison.OrdinalIgnoreCase) >= 0 &&
                name.ToString().IndexOf(OSKAR_PID, StringComparison.OrdinalIgnoreCase) >= 0;
            deviceCache[deviceHandle] = isOskar;
            return isOskar;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTDEVICE {
        public ushort usUsagePage;
        public ushort usUsage;
        public int dwFlags;
        public IntPtr hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTHEADER {
        public uint dwType;
        public uint dwSize;
        public IntPtr hDevice;
        public IntPtr wParam;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices(
        [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] RAWINPUTDEVICE[] pRawInputDevices,
        uint uiNumDevices,
        uint cbSize
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(
        IntPtr hRawInput,
        uint uiCommand,
        IntPtr pData,
        ref uint pcbSize,
        uint cbSizeHeader
    );

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern uint GetRawInputDeviceInfo(
        IntPtr hDevice,
        uint uiCommand,
        StringBuilder pData,
        ref uint pcbSize
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputDeviceInfo(
        IntPtr hDevice,
        uint uiCommand,
        IntPtr pData,
        ref uint pcbSize
    );
}
