import nextVitals from 'eslint-config-next/core-web-vitals';

const config = [
  ...nextVitals,
  {
    files: ['**/*.{ts,tsx}'],
    rules: {
      '@typescript-eslint/no-explicit-any': 'warn',
      '@typescript-eslint/no-unused-vars': [
        'warn',
        {
          argsIgnorePattern: '^_',
        },
      ],
      'react/no-unescaped-entities': 'off',
      'prefer-const': 'warn',
      'no-console': [
        'warn',
        {
          allow: ['warn', 'error'],
        },
      ],
    },
  },
  // Existing React 18 screens predate these React Compiler diagnostics.
  // Keep them visible while new screens use the preset's error severity.
  {
    files: [
      'src/app/admin/audit/page.tsx',
      'src/app/admin/page.tsx',
      'src/app/catalogue/page.tsx',
      'src/app/service/page.tsx',
      'src/components/billing/BusinessSettings.tsx',
      'src/components/billing/DocumentEditor.tsx',
      'src/components/customers/CustomerAssetsPanel.tsx',
      'src/components/layout/AppShell.tsx',
      'src/components/ui/ConfirmDialog.tsx',
      'src/components/workshop/Attachments.tsx',
    ],
    rules: {
      'react-hooks/set-state-in-effect': 'warn',
      'react-hooks/purity': 'warn',
    },
  },
];
export default config;
