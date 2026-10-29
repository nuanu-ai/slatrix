package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.SignInOptions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
fun AccountProviderScreen(
    homeserver: String, onHomeserver: (String) -> Unit, connecting: Boolean, error: String?,
    onContinue: () -> Unit, onCancel: () -> Unit,
) {
    val focus = LocalFocusManager.current
    val submit = { if (homeserver.isNotBlank() && !connecting) { focus.clearFocus(); onContinue() } }
    AccountLayout("Sign in to Slatrix", error = error) {
        OutlinedTextField(homeserver, onHomeserver, label = { Text("Homeserver") },
            placeholder = { Text("matrix.org") }, singleLine = true, enabled = !connecting,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { submit() }), modifier = Modifier.fillMaxWidth())
        AccountAction("Continue", homeserver.isNotBlank() && !connecting, submit)
        ConnectionIndicator(connecting, onCancel)
    }
}

@Composable
fun SignInMethodsScreen(
    options: SignInOptions, connecting: Boolean, error: String?,
    onSignIn: (String, String) -> Unit, onBrowser: () -> Unit, onBack: () -> Unit,
) {
    var username by rememberSaveable(options.homeserver) { mutableStateOf("") }
    // Passwords must never enter the Activity's saved-state bundle.
    var password by remember(options.homeserver) { mutableStateOf("") }
    val focus = LocalFocusManager.current
    val complete = username.isNotBlank() && password.isNotEmpty()
    val submit = { if (complete && !connecting) { focus.clearFocus(); onSignIn(username, password) } }
    AccountLayout("Sign in", options.homeserver, error, onBack) {
        if (options.password && !options.oauth) {
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
            AccountAction("Sign in", complete && !connecting, submit)
            if (options.sso) OutlinedButton(onClick = onBrowser, enabled = !connecting,
                shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth()) { Text("Continue in browser") }
        } else if (options.oauth || options.sso) {
            AccountAction("Continue in browser", !connecting, onBrowser)
        }
        ConnectionIndicator(connecting, onBack)
    }
}

@Composable
fun BrowserSignInScreen(provider: String, error: String?, onOpen: () -> Unit, onCancel: () -> Unit) {
    AccountLayout("Complete sign in", provider, error, onCancel) {
        AccountAction("Open browser", true, onOpen)
    }
}

@Composable
fun RestoreSessionScreen(connecting: Boolean, error: String?, onRetry: () -> Unit, onCancel: () -> Unit) {
    AccountLayout("Restore your session", error = error) {
        AccountAction("Try again", !connecting, onRetry)
        ConnectionIndicator(connecting, onCancel)
    }
}

@Composable
internal fun AccountLayout(
    title: String, provider: String? = null, error: String? = null, onBack: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = SlatrixTheme.colors
    Surface(Modifier.fillMaxSize(), color = colors.canvas) {
        Box(Modifier.safeDrawingPadding().imePadding().fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = UiMetrics.FormWidth).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(UiMetrics.GapSection), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                onBack?.let { IconButton(onClick = it) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } }
                Text(title, style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.padding(top = UiMetrics.GapSection, bottom = UiMetrics.GapSmall))
                provider?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary) }
                content()
            }
            if (error != null) Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)
                .semantics { liveRegion = LiveRegionMode.Polite }) { Text(error) }
        }
    }
}

@Composable
internal fun AccountAction(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Button(onClick, enabled = enabled, shape = MaterialTheme.shapes.small,
        colors = ButtonDefaults.buttonColors(containerColor = colors.buttonPrimary, contentColor = colors.onAccent),
        modifier = Modifier.fillMaxWidth()) { Text(label) }
}

@Composable
internal fun ConnectionIndicator(connecting: Boolean, onCancel: (() -> Unit)?) {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(connecting) {
        visible = false
        if (connecting) { delay(UiMetrics.ProgressDelayMillis); visible = true }
    }
    Box(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch), contentAlignment = Alignment.Center) {
        if (connecting && onCancel != null) TextButton(onClick = onCancel, shape = MaterialTheme.shapes.small) { Text("Cancel") }
        if (visible) CircularProgressIndicator(Modifier.align(Alignment.CenterEnd).size(UiMetrics.Icon))
    }
}
