'use client';

import { createContext, useContext, useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';

type Access = {
  role: string | null;
  email: string;
  permissions: string[];
};

const Context = createContext<Access & { can: (permission: string) => boolean }>({
  role: null,
  email: '',
  permissions: [],
  can: () => false,
});

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [access, setAccess] = useState<Access>({
    role: null,
    email: '',
    permissions: [],
  });

  useEffect(() => {
    let alive = true;

    const refresh = async () => {
      if (!supabase) return;

      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        if (alive) setAccess({ role: null, email: '', permissions: [] });
        return;
      }

      const { data, error } = await supabase.rpc('my_access');
      if (alive) {
        setAccess(
          !error && data ? data : { role: null, email: user.email || '', permissions: [] }
        );
      }
    };

    void refresh();
    const timer = setInterval(refresh, 15000);
    window.addEventListener('focus', refresh);

    return () => {
      alive = false;
      clearInterval(timer);
      window.removeEventListener('focus', refresh);
    };
  }, []);

  return (
    <Context.Provider
      value={{
        ...access,
        can: (p) => access.role === 'owner' || access.permissions.includes(p),
      }}
    >
      {children}
    </Context.Provider>
  );
}

export const useAuth = () => useContext(Context);
