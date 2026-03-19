import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("lockpaw://unlock");
  await showHUD("Lockpaw unlock requested");
}
