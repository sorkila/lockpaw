import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("bevaka://unlock");
  await showHUD("Bevaka unlock requested");
}
