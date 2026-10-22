class _Registry:
    def register(self):
        return lambda cls: cls
ARCH_REGISTRY = _Registry()
