package local.planner.android

import com.google.gson.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class FolderOrderTest {
    @Test
    fun localOrderDropsMissingFoldersAndAppendsNewOnes() {
        assertEquals(listOf("b", "a", "c"), mergeFolderOrder(listOf("removed", "b", "b", "a"), listOf("a", "b", "c")))
        assertEquals(listOf("b", "c", "a"), listOf("a", "b", "c").moveFolder("a", 2))
    }

    @Test
    fun displayOrderDoesNotChangeSyncedFolderFields() {
        val first = Entity("a", "folder", mapOf("sortOrder" to JsonPrimitive(0)))
        val second = Entity("b", "folder", mapOf("sortOrder" to JsonPrimitive(1)))
        val third = Entity("c", "folder", mapOf("sortOrder" to JsonPrimitive(2)))
        val library = Library(entities = listOf(first, second, third), folderOrder = listOf("b", "a"))
        assertEquals(listOf(second, first, third), library.folders)
        assertEquals(listOf(first, second, third), library.entities)
    }
}
