package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.CropSquare
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.ImageBitmap

@Composable
fun EditProfileScreen(userId: String, name: String, photo: ImageBitmap?, hasPhoto: Boolean, saving: Boolean, error: String?,
    onPickPhoto: () -> Unit, onRemovePhoto: () -> Unit, onSave: (String) -> Unit, onBack: () -> Unit) {
}

@Composable
fun PhotoCropScreen(photo: ImageBitmap, onCancel: () -> Unit, onSave: (CropSquare) -> Unit) {
}
