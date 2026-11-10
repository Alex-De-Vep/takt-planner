package local.planner.android

import android.content.Context
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
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
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    private val model by viewModels<PlannerModel>()

    override fun attachBaseContext(newBase: Context) {
        restoreInterfacePreferences(newBase)
        super.attachBaseContext(newBase)
    }

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
    val library by model.library.collectAsState()
    val cloud by model.cloud.collectAsState()
    val ready by model.ready.collectAsState()
    val error by model.error.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    val errorMessage = error?.let { stringResource(it) }
    LaunchedEffect(errorMessage) {
        if (errorMessage != null) {
            snackbar.showSnackbar(errorMessage)
            model.clearError()
        }
    }
    if (ready && !cloud.closing) {
        if (library.profile != null) {
            key(library.workspace) { Workspace(library, cloud, model, snackbar) }
        } else {
            AccountEntry(cloud, model)
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
    primary = Color(0xFF7650B5), onPrimary = Color.White,
    primaryContainer = Color(0xFFEEE7FA), onPrimaryContainer = Color(0xFF24163F),
    secondaryContainer = Color(0xFFEEE7FA), onSecondaryContainer = Color(0xFF3E2965),
    background = Color(0xFFFDFBFF), onBackground = Color(0xFF1F1F1F),
    surface = Color(0xFFFDFBFF), onSurface = Color(0xFF1F1F1F),
    surfaceContainer = Color(0xFFF0F4F9), surfaceContainerHigh = Color(0xFFE7EDF6),
    surfaceContainerLow = Color(0xFFF7F9FC), onSurfaceVariant = Color(0xFF444746),
    outlineVariant = Color(0xFFDADCE0),
)

private val DarkPalette = darkColorScheme(
    primary = Color(0xFFB79BEA), onPrimary = Color(0xFF2D174F),
    primaryContainer = Color(0xFF3D2D58), onPrimaryContainer = Color(0xFFEEE7FA),
    secondaryContainer = Color(0xFF3D2D58), onSecondaryContainer = Color(0xFFEEE7FA),
    background = Color(0xFF131314), onBackground = Color(0xFFE3E3E3),
    surface = Color(0xFF131314), onSurface = Color(0xFFE3E3E3),
    surfaceContainer = Color(0xFF1E1F20), surfaceContainerHigh = Color(0xFF282A2D),
    surfaceContainerLow = Color(0xFF191A1C), onSurfaceVariant = Color(0xFFC4C7C5),
    outlineVariant = Color(0xFF444746),
)
