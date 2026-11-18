@Composable
fun TopBarIconButton(onTap: () -> Unit) {
    Box(Modifier.clickable(interactionSource = source, indication = TopBarRipple) { onTap() })
}
