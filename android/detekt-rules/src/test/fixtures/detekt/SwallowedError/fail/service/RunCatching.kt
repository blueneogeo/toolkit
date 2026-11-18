fun load(): String? = runCatching { read() }.getOrNull()
