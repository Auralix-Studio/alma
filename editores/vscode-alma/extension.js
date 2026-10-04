// Extensión de Alma para VS Code: comando «Alma: ejecutar archivo».
// Ejecuta `alma ejecutar <archivo>` como tarea (sin pasar por el shell, así no
// hay problemas de comillas) y usa el problem matcher `$alma` para marcar en el
// editor los errores `archivo:línea:columna: mensaje` que imprime `alma`.
const vscode = require("vscode");
const { execFile } = require("child_process");
const path = require("path");

const URL_INSTALACION = "https://github.com/Auralix-Studio/alma#instalar";

function ejecutable() {
  const ruta = vscode.workspace.getConfiguration("alma").get("rutaEjecutable");
  return ruta && ruta.trim() !== "" ? ruta.trim() : "alma";
}

/** Comprueba que `alma` responde; si no, ofrece instalarlo o configurarlo. */
function comprobarAlma(alma) {
  return new Promise((resolver) => {
    execFile(alma, ["version"], { timeout: 10000 }, async (error) => {
      if (!error) return resolver(true);
      const eleccion = await vscode.window.showErrorMessage(
        `No se pudo ejecutar «${alma}». Instala Alma o indica su ruta en el ajuste «alma.rutaEjecutable».`,
        "Cómo instalar",
        "Abrir ajustes"
      );
      if (eleccion === "Cómo instalar") vscode.env.openExternal(vscode.Uri.parse(URL_INSTALACION));
      if (eleccion === "Abrir ajustes") vscode.commands.executeCommand("workbench.action.openSettings", "alma.rutaEjecutable");
      resolver(false);
    });
  });
}

async function ejecutarArchivo(uri) {
  const documento = uri instanceof vscode.Uri
    ? await vscode.workspace.openTextDocument(uri)
    : vscode.window.activeTextEditor && vscode.window.activeTextEditor.document;
  if (!documento || documento.languageId !== "alma") {
    vscode.window.showWarningMessage("Abre un archivo .alma para ejecutarlo.");
    return;
  }
  if (documento.isUntitled) {
    vscode.window.showWarningMessage("Guarda el archivo antes de ejecutarlo.");
    return;
  }
  if (documento.isDirty && !(await documento.save())) return;

  const alma = ejecutable();
  if (!(await comprobarAlma(alma))) return;

  const archivo = documento.uri.fsPath;
  const carpeta = vscode.workspace.getWorkspaceFolder(documento.uri);
  const tarea = new vscode.Task(
    { type: "alma", archivo },
    carpeta || vscode.TaskScope.Workspace,
    `ejecutar ${path.basename(archivo)}`,
    "alma",
    new vscode.ProcessExecution(alma, ["ejecutar", archivo], { cwd: path.dirname(archivo) }),
    ["$alma"]
  );
  tarea.presentationOptions = {
    reveal: vscode.TaskRevealKind.Always,
    clear: true,
    focus: false,
    panel: vscode.TaskPanelKind.Dedicated,
  };
  await vscode.tasks.executeTask(tarea);
}

function activate(contexto) {
  contexto.subscriptions.push(vscode.commands.registerCommand("alma.ejecutarArchivo", ejecutarArchivo));
}

function deactivate() {}

module.exports = { activate, deactivate };
