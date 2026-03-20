/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `lock` command */
  export type Lock = ExtensionPreferences & {}
  /** Preferences accessible in the `unlock` command */
  export type Unlock = ExtensionPreferences & {}
  /** Preferences accessible in the `unlock-password` command */
  export type UnlockPassword = ExtensionPreferences & {}
  /** Preferences accessible in the `toggle` command */
  export type Toggle = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `lock` command */
  export type Lock = {}
  /** Arguments passed to the `unlock` command */
  export type Unlock = {}
  /** Arguments passed to the `unlock-password` command */
  export type UnlockPassword = {}
  /** Arguments passed to the `toggle` command */
  export type Toggle = {}
}

