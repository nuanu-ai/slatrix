package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import kotlinx.coroutines.delay

@Composable
fun SignInScreen(
    connecting: Boolean,
    error: String?,
    onSignIn: (String, String, String) -> Unit,
    onCancel: () -> Unit,
    onRetryRestore: (() -> Unit)?,
) {
    var homeserver by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    // Passwords must never enter the Activity's saved-state bundle.
    var password by remember { mutableStateOf("") }
    var showProgress by remember { mutableStateOf(false) }
    LaunchedEffect(connecting) {
        showProgress = false
        if (connecting) { delay(UiMetrics.ProgressDelayMillis); showProgress = true }
    }
    val focus = LocalFocusManager.current
    val complete = homeserver.isNotBlank() && username.isNotBlank() && password.isNotEmpty()
    val submit = {
        if (complete && !connecting) { focus.clearFocus(); onSignIn(homeserver, username, password) }
    }
    val colors = SlatrixTheme.colors
    Surface(Modifier.fillMaxSize(), color = colors.canvas) {
        Box(Modifier.safeDrawingPadding().imePadding().fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = UiMetrics.FormWidth).fillMaxWidth()
                    .verticalScroll(rememberScrollState()).padding(UiMetrics.GapSection),
                verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
            ) {
                Text(if (onRetryRestore == null) "Sign in to Slatrix" else "Restore your session",
                    style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.padding(top = UiMetrics.GapSection, bottom = UiMetrics.GapSmall))
                if (onRetryRestore == null) {
                    OutlinedTextField(homeserver, { homeserver = it }, label = { Text("Homeserver") },
                        placeholder = { Text("matrix.org") }, singleLine = true, enabled = !connecting,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Next),
                        keyboardActions = KeyboardActions(onNext = { focus.moveFocus(FocusDirection.Down) }),
                        modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(username, { username = it }, label = { Text("Username") },
                        singleLine = true, enabled = !connecting,
                        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Next),
                        keyboardActions = KeyboardActions(onNext = { focus.moveFocus(FocusDirection.Down) }),
                        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.Username })
                    OutlinedTextField(password, { password = it }, label = { Text("Password") },
                        singleLine = true, enabled = !connecting, visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { submit() }),
                        modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.Password })
                    Button(onClick = submit, enabled = complete && !connecting,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.buttonPrimary, contentColor = colors.onAccent),
                        modifier = Modifier.fillMaxWidth()) { Text("Sign in") }
                } else {
                    Button(onClick = onRetryRestore, enabled = !connecting, modifier = Modifier.fillMaxWidth()) { Text("Try again") }
                }
                Box(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch), contentAlignment = Alignment.Center) {
                    if (connecting) TextButton(onClick = onCancel) { Text("Cancel") }
                    if (showProgress) CircularProgressIndicator(Modifier.align(Alignment.CenterEnd).size(UiMetrics.Icon))
                }
            }
            if (error != null) Snackbar(
                modifier = Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            ) { Text(error) }
        }
    }
}
