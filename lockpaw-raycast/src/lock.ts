import { confirmAlert, open, showHUD, Alert } from "@raycast/api";

export default async function Command() {
  if (
    await confirmAlert({
      title: "Lock Screen",
      message: "Activate the Lockpaw lock screen?",
      primaryAction: { title: "Lock", style: Alert.ActionStyle.Default },
    })
  ) {
    await open("lockpaw://lock");
    await showHUD("Lockpaw locked");
  }
}
