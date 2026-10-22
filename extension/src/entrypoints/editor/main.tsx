import { render } from 'preact';
import '@/styles/glass.css';
import './editor.css';
import { Editor } from './Editor';

render(<Editor />, document.getElementById('app')!);
