'use client';
import { Printer } from 'lucide-react';
export function PrintButton(){return <button className="primary-button" onClick={()=>window.print()}><Printer size={16}/>Print / Save as PDF</button>}
