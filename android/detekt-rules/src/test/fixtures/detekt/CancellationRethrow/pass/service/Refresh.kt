suspend fun refresh() {
    try {
        load()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Log.error(error, msg = "refresh failed", cat = "feed")
    }
}

suspend fun again() {
    try {
        load()
    } catch (error: Exception) {
        if (error is CancellationException) throw error
        Log.error(error, msg = "refresh failed", cat = "feed")
    }
}

suspend fun narrow() {
    try {
        load()
    } catch (error: IOException) {
        Log.error(error, msg = "refresh failed", cat = "feed")
    }
}

fun plain() {
    try {
        load()
    } catch (error: Exception) {
        Log.error(error, msg = "refresh failed", cat = "feed")
    }
}
