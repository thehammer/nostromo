import chokidar from 'chokidar';

chokidar.watch('notes').on('change', (p) => console.log('changed', p));
