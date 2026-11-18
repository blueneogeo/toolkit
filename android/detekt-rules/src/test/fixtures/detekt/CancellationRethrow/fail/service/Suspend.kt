suspend fun refresh() {
    try {
        load()
    } catch (error: Exception) {
        Log.error(error, msg = "refresh failed", cat = "feed")
    }
}
