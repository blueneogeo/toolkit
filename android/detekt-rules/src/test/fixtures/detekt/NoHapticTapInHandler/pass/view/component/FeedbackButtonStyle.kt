fun Modifier.pressFeedback(source: InteractionSource): Modifier =
    composed {
        LaunchedEffect(source) { source.interactions.collect { if (it is PressInteraction.Press) Haptics.tap() } }
        this
    }
