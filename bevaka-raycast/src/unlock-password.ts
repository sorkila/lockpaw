import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("bevaka://unlock-password");
  await showHUD("Bevaka password unlock requested");
}
