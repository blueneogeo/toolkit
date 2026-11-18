fun AppState.onFeedRefreshTriggered() {
    scope.launch {
        try {
            load()
        } catch (error: Throwable) {
            Log.error(error, msg = "refresh failed", cat = "feed")
        }
    }
}
