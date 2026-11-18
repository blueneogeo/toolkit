fun AppState.onPaperCardTapped(conversationID: String, frame: Rect) {
    Haptics.tap()
    open(conversationID, frame)
}
