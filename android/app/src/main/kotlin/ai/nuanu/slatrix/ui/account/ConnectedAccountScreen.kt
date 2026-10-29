package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.IdentityPhase
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Snackbar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign

@Composable
fun ConnectedAccountScreen(
    identity: IdentityState,
    onRequest: () -> Unit, onAccept: () -> Unit, onConfirm: () -> Unit, onReject: () -> Unit,
    onRecover: (String) -> Unit, onCancel: () -> Unit, onRetry: () -> Unit,
    content: @Composable () -> Unit,
) {
    if (!identity.requiresVerification) {
        content()
        return
    }
    var recovery by remember { mutableStateOf(false) }
    var key by remember { mutableStateOf("") }
    val comparing = identity.phase == IdentityPhase.Comparing
    AccountLayout(if (comparing) "Compare codes" else "Confirm it’s you", error = identity.error) {
        when {
            recovery && identity.phase in listOf(IdentityPhase.ChooseMethod, IdentityPhase.Failed, IdentityPhase.Recovering) -> {
                OutlinedTextField(key, { key = it }, label = { Text("Recovery key") },
                    visualTransformation = PasswordVisualTransformation(), enabled = identity.phase != IdentityPhase.Recovering,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { if (key.isNotBlank()) onRecover(key) }), modifier = Modifier.fillMaxWidth())
                AccountAction("Use recovery key", key.isNotBlank() && identity.phase != IdentityPhase.Recovering) { onRecover(key) }
                TextButton(onClick = { key = ""; recovery = false; onCancel() }, shape = MaterialTheme.shapes.small) { Text("Back") }
                ConnectionIndicator(identity.phase == IdentityPhase.Recovering, onCancel)
            }
            comparing -> {
                Text("Compare these with your other device.", style = MaterialTheme.typography.bodyLarge)
                if (identity.emojis.isNotEmpty()) identity.emojis.chunked(4).forEach { group ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                        group.forEach { emoji ->
                            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(emoji.symbol, style = MaterialTheme.typography.headlineMedium)
                                Text(emoji.name, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center)
                            }
                        }
                    }
                } else Text(identity.decimals.joinToString(" · "), style = MaterialTheme.typography.headlineSmall)
                AccountAction("They match", onClick = onConfirm)
                OutlinedButton(onClick = onReject, shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth()) { Text("They don’t match") }
            }
            identity.phase == IdentityPhase.Incoming -> {
                identity.requestDeviceName?.let { Text(it, style = MaterialTheme.typography.bodyLarge) }
                AccountAction("Continue", onClick = onAccept)
                TextButton(onClick = onCancel, shape = MaterialTheme.shapes.small) { Text("Cancel") }
            }
            identity.phase == IdentityPhase.ChooseMethod || identity.phase == IdentityPhase.Failed -> {
                if (identity.hasOtherDevice == true) AccountAction("Use another device", onClick = onRequest)
                if (identity.recoveryAvailable == true) OutlinedButton(onClick = { recovery = true },
                    shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth()) { Text("Use recovery key") }
                if (identity.phase == IdentityPhase.Failed || identity.hasOtherDevice != true && identity.recoveryAvailable != true)
                    AccountAction("Try again", onClick = onRetry)
            }
            else -> {
                if (identity.phase != IdentityPhase.Preparing) Text("Check your other device.", style = MaterialTheme.typography.bodyLarge)
                ConnectionIndicator(true, if (identity.phase == IdentityPhase.Preparing) null else onCancel)
            }
        }
    }
}

