@Composable
fun Toggle(on: Boolean, onChange: (Boolean) -> Unit) {
    Box(Modifier.toggleable(value = on, interactionSource = null, indication = ripple(), onValueChange = onChange))
}
