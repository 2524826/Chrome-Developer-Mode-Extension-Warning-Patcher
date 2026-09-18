using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Vanara.Extensions;
using Vanara.PInvoke;

namespace ChromeDllInjector {
	internal class Injector {
		private readonly string dllPath;

		public Injector(string dllPath) {
			this.dllPath = dllPath;
		}

		public void Inject(Process process) {
			Kernel32.SafeHPROCESS target = Kernel32.OpenProcess(new ACCESS_MASK(Kernel32.ProcessAccess.PROCESS_ALL_ACCESS), false, (uint)process.Id);
			if (target.IsNull || target.IsInvalid) {
				return;
			}

			IntPtr allocation = IntPtr.Zero;
			try {
				IntPtr loadLibrary = Kernel32.GetProcAddress(Kernel32.LoadLibrary("kernel32.dll"), "LoadLibraryW");
				if (loadLibrary == IntPtr.Zero) {
					return;
				}

				byte[] dllPathBytes = dllPath.GetBytes(true, CharSet.Unicode);
				allocation = Kernel32.VirtualAllocEx(target, IntPtr.Zero, dllPathBytes.Length, Kernel32.MEM_ALLOCATION_TYPE.MEM_COMMIT, Kernel32.MEM_PROTECTION.PAGE_EXECUTE_READWRITE);
				if (allocation == IntPtr.Zero || !Kernel32.WriteProcessMemory(target, allocation, dllPathBytes, dllPathBytes.Length, out _)) {
					return;
				}

				Kernel32.SafeHTHREAD thread = Kernel32.CreateRemoteThread(target, null, 0, loadLibrary, allocation, 0, out _);
				if (thread.IsNull || thread.IsInvalid) {
					return;
				}

				Kernel32.WaitForSingleObject(thread, Kernel32.INFINITE);
				thread.Close();
			} finally {
				if (allocation != IntPtr.Zero) {
					Kernel32.VirtualFreeEx(target, allocation, 0, Kernel32.MEM_ALLOCATION_TYPE.MEM_RELEASE);
				}
				target.Close();
			}
		}
	}
}
