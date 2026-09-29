# Dragonwilds Model Viewer

A browser app for finding the game's 3D objects (castle walls, towers, furniture, props) so they can be picked for the toolkit's building features later. It is not a UE4SS mod and `deploy.ps1` does not touch it.

It shows every exported model as a thumbnail grid you can search and filter by folder, opens any model in a 3D view you can orbit, and shows its in-game object path (for example `/Game/Art/Env/Base_Building/Furniture/Cosiness/Chest/SM_Storage_Chest_01v2.SM_Storage_Chest_01v2`). That path is what a UE4SS mod passes to `StaticFindObject` to load the mesh in game. You can star the models you like and download the starred list as `starred-objects.json`.

Nothing is uploaded. The page reads the files straight from your disk.

## 1. Export the models with FModel

1. Download [FModel](https://fmodel.app) and open it.
2. **Settings > General**
   - *Archive Directory*: `<Steam>\steamapps\common\RSDragonwilds\RSDragonwilds\Content\Paks`
   - *UE Versions*: `GAME_UE5_6` (the game runs Unreal Engine 5.6, per `UE4SS.log`).
3. **Mappings file.** UE5 games need one to read their assets. In game with UE4SS running, open the UE4SS console and use *Dumpers > Generate .usmap file* (or its keybind, Ctrl+Numpad 6 by default). It writes `Mappings.usmap` next to the game exe. In FModel, go to **Settings > General > Local Mapping File** and pick it.
4. If FModel asks for an **AES key**, the paks are encrypted and you need the game's key (the Dragonwilds modding community usually publishes it). If it opens without asking, skip this.
5. **Settings > Models > Mesh Export Format**: `glTF 2.0 (binary)`.
6. In the **Archives** tab, load all archives. In **Folders**, go to `RSDragonwilds/Content/Art/Env` (buildings, walls and props live there; base building pieces are under `Base_Building`), right-click the folder and choose **Export Folder's Packages Models**. Export more folders the same way if you want them.

FModel writes to its `Output\Exports` folder by default.

## 2. Open the viewer

Open `ModelViewer/index.html` in Chrome or Edge, click **Open export folder** and pick FModel's `Output\Exports` folder (or any folder under it). You can also drag the folder onto the page.

If the page stays blank when opened by double-click, serve it instead: in the `ModelViewer` folder run `python -m http.server 8000` and open `http://localhost:8000`.

The page loads three.js from jsDelivr, so it needs an internet connection.

## Notes

- Models may show in flat colours. FModel's glTF export usually writes textures as separate files that the mesh does not link to. Shapes and sizes are what matter for finding objects.
- Sizes are shown in the export's units. FModel's glTF export normally converts Unreal centimetres to metres.
- Big castles are usually built from many pieces (walls, towers, roofs), so search for parts like `wall`, `tower`, `battlement`, `gate`.
- Folder and type filters use the object path. `SM_` is a static mesh (the usual choice for placeable pieces). `SK_` is a skeletal (animated) mesh.
- Stars are kept in your browser for this page.
