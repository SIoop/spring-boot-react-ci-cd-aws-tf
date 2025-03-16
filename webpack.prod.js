const common = require('./webpack.common.js');
const { merge } = require('webpack-merge');
var path = require('path');
const CopyWebpackPlugin = require('copy-webpack-plugin');

module.exports = merge(common, {
    mode: 'production',
    output: {
        path: path.resolve(__dirname, 'build'),
        filename: 'built/bundle.js'
    },
    plugins: [
    
        // Copies static assets like CSS
        new CopyWebpackPlugin({
          patterns: [
            { from: '*.css', context: path.resolve(__dirname, 'src/main/resources/static/')}, // Moves CSS to /build/
            { from:'*.html', context: path.resolve(__dirname, 'src/main/resources/templates/')}, // Moves HTML to /build/
          ],
        }),
      ],
});