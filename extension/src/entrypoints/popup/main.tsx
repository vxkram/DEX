import { render } from 'preact';
import '@/styles/glass.css';
import './popup.css';
import { Popup } from './Popup';

render(<Popup />, document.getElementById('app')!);
