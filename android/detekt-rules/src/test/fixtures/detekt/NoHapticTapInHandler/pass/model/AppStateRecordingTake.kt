fun AppState.startTakeAfterCountdown() {
    recording.countdownTask = scope.launch {
        for (number in listOf(3, 2, 1)) {
            if (number < 3) Haptics.tap()
            recording.countdown = number
        }
    }
}
