using System;

namespace ChromeDllInjector {
	public interface IProcessListener {
		void StartListener(Action<int> callback);
	}
}
