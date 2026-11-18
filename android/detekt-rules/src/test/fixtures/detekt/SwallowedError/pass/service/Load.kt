fun load(): String? {
    try {
        return read()
    } catch (error: IOException) {
        Log.error(error, msg = "read failed", cat = "error")
        return null
    }
}

fun loadOrThrow(): String {
    try {
        return read()
    } catch (error: IOException) {
        throw APIError.from(error)
    }
}

fun cleanUp() {
    try {
        file.delete()
    } catch (error: IOException) { // non-actionable: a stale temp file is removed on the next launch
    }
}

fun quick(): String? = runCatching { read() }.onFailure { Log.error(it, msg = "read failed", cat = "error") }.getOrNull()

fun quiet(): String? = runCatching { read() }.getOrNull() // non-actionable: the cache is optional
