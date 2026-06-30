import { defineConfig } from 'checkly'

// Checkly monitoring-as-code project for QuickNotes synthetic monitoring.
// Deploy with the Checkly CLI: see README.md in this directory.
export default defineConfig({
  projectName: 'QuickNotes Synthetic Monitoring',
  logicalId: 'quicknotes-synthetic',
  checks: {
    // Pick up every *.check.ts file in this directory.
    checkMatch: '**/*.check.ts',
  },
})
