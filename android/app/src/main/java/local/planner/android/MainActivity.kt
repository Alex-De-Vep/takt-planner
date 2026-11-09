package local.planner.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val model by viewModels<PlannerModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                while (true) {
                    model.refresh()
                    delay(30_000)
                }
            }
        }
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkPalette else LightPalette) {
                Planner(model)
            }
        }
    }
}

@Composable
private fun Planner(model: PlannerModel) {
    val context = LocalContext.current
    val library by model.library.collectAsState()
    val cloud by model.cloud.collectAsState()
    val ready by model.ready.collectAsState()
    val error by model.error.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(error) {
        error?.let { snackbar.showSnackbar(context.getString(it)); model.clearError() }
    }
    if (ready) {
        key(library.workspace) {
            Workspace(library, cloud, model, snackbar)
        }
    } else {
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                if (error == null) CircularProgressIndicator()
            }
        }
    }
}

private val LightPalette = lightColorScheme(
    primary = Color(0xFF5143AE), onPrimary = Color.White,
    primaryContainer = Color(0xFFE6E1FF), onPrimaryContainer = Color(0xFF23185F),
    secondaryContainer = Color(0xFFE9E5F6), onSecondaryContainer = Color(0xFF252139),
    background = Color(0xFFF9F8FF), onBackground = Color(0xFF201D2A),
    surface = Color(0xFFF9F8FF), onSurface = Color(0xFF201D2A),
    surfaceContainer = Color(0xFFF0EDF9), surfaceContainerHigh = Color(0xFFEAE6F4),
    surfaceContainerLow = Color(0xFFF5F2FC), onSurfaceVariant = Color(0xFF555166),
    outlineVariant = Color(0xFFDAD5E8),
)

private val DarkPalette = darkColorScheme(
    primary = Color(0xFFC8BFFF), onPrimary = Color(0xFF2C2267),
    primaryContainer = Color(0xFF3E327E), onPrimaryContainer = Color(0xFFE7E1FF),
    secondaryContainer = Color(0xFF39354C), onSecondaryContainer = Color(0xFFEAE3FA),
    background = Color(0xFF12121A), onBackground = Color(0xFFF0ECF9),
    surface = Color(0xFF12121A), onSurface = Color(0xFFF0ECF9),
    surfaceContainer = Color(0xFF22212D), surfaceContainerHigh = Color(0xFF2D2B38),
    surfaceContainerLow = Color(0xFF1B1A25), onSurfaceVariant = Color(0xFFCEC8E0),
    outlineVariant = Color(0xFF494558),
)
