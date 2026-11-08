import { modules, roleLabels } from '@/lib/auth/permissions';

export function RolePermissionMatrix({
  role,
  disabled,
  permissions,
  onChange,
}: {
  role: string;
  disabled: boolean;
  permissions: string[];
  onChange: (values: string[]) => void;
}) {
  function toggle(moduleName: string, action: string, checked: boolean) {
    const value = moduleName + '.' + action;
    if (checked) onChange([...new Set([...permissions, moduleName + '.read', value])]);
    else
      onChange(
        permissions.filter(
          (p) => p !== value && !(action === 'read' && p.startsWith(moduleName + '.'))
        )
      );
  }
  return (
    <div className="permission-table">
      <div className="permission-row permission-header">
        <span>Module</span>
        <span>View</span>
        <span>Edit</span>
      </div>
      {modules.map((m) => (
        <div key={m} className="permission-row">
          <span className="capitalize">{m.replaceAll('_', ' ')}</span>
          {['read', 'write'].map((a) => (
            <input
              key={a}
              type="checkbox"
              aria-label={roleLabels[role] + ' ' + m + ' ' + a}
              disabled={disabled || (m === 'dashboard' && a === 'write')}
              checked={permissions.includes(m + '.' + a)}
              onChange={(e) => toggle(m, a, e.target.checked)}
            />
          ))}
        </div>
      ))}
      <label>
        <input
          type="checkbox"
          disabled={disabled}
          checked={permissions.includes('vehicles.export')}
          onChange={(e) => toggle('vehicles', 'export', e.target.checked)}
        />{' '}
        Export vehicle records
      </label>
    </div>
  );
}
