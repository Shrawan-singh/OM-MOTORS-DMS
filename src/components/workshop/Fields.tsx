'use client';
import {Row,label} from '@/lib/workshop/types';
import {useId} from 'react';
export function Field({title,name,value,change,type='text',options,required=false,disabled=false}:{title?:string;name:string;value:Row;change:(key:string,value:any)=>void;type?:string;options?:{value:string;label:string}[];required?:boolean;disabled?:boolean}){
 const fieldId=useId();const props={id:`field-${name}-${fieldId}`,name,disabled,required,value:value[name]??'',onChange:(e:React.ChangeEvent<HTMLInputElement|HTMLSelectElement|HTMLTextAreaElement>)=>change(name,type==='number'?(e.target.value===''?null:Number(e.target.value)):type==='date'?(e.target.value||null):e.target.value)};
 return <label className={type==='textarea'?'ws-field ws-wide':'ws-field'} htmlFor={props.id}>{title||label(name)}{options?<select {...props}><option value="">Select…</option>{options.map(o=><option key={o.value} value={o.value}>{o.label}</option>)}</select>:type==='textarea'?<textarea {...props} rows={3}/>:<input {...props} type={type} min={type==='number'?0:undefined} step={type==='number'?'0.01':undefined}/>}</label>
}
export function Badge({value}:{value:string}){return <span className={`ws-badge ws-${value.toLowerCase().replaceAll(' ','_')}`}>{label(value)}</span>}
